#!/bin/bash
# auto-dispatch.sh — Fetch issue → LLM analyze → create sub-issues → dispatch

API_URL="${PAPERCLIP_API_URL:-http://localhost:3100/api}"
API_KEY="${PAPERCLIP_API_KEY:-}"
AGENT_ID="${PAPERCLIP_AGENT_ID:-}"
COMPANY_ID="${PAPERCLIP_COMPANY_ID:-}"
ADAPTER_URL="${ADAPTER_URL:-http://localhost:8650}"
OPENROUTER_KEY="${OPENROUTER_API_KEY:-}"
LLM_MODEL="${LLM_MODEL:-qwen/qwen3-coder}"

[ -z "$API_KEY" ] && echo "[orch] No API_KEY" && exit 1
[ -z "$COMPANY_ID" ] && echo "[orch] No COMPANY_ID" && exit 1

ISSUES=$(curl -s -H "Authorization: Bearer $API_KEY" "$API_URL/companies/$COMPANY_ID/issues?assigneeAgentId=$AGENT_ID" 2>/dev/null || echo "[]")

export ISSUES API_URL API_KEY COMPANY_ID ADAPTER_URL OPENROUTER_KEY LLM_MODEL

python3 << 'PYEOF'
import json, urllib.request, sys, re, os

api_url = os.environ.get("API_URL", "http://localhost:3100/api")
api_key = os.environ.get("API_KEY", "")
company_id = os.environ.get("COMPANY_ID", "")
adapter_url = os.environ.get("ADAPTER_URL", "http://localhost:8650")
or_key = os.environ.get("OPENROUTER_KEY", "")
model = os.environ.get("LLM_MODEL", "qwen/qwen3-coder")
issues_raw = os.environ.get("ISSUES", "[]")

headers = {"Content-Type": "application/json", "Authorization": f"Bearer {api_key}"}

def api_get(path):
    try:
        req = urllib.request.Request(f"{api_url}{path}", headers=headers)
        return json.loads(urllib.request.urlopen(req).read().decode())
    except Exception as e:
        print(f"[orch] GET error: {e}")
        return None

def api_post(path, data):
    try:
        body = json.dumps(data).encode()
        req = urllib.request.Request(f"{api_url}{path}", data=body, headers=headers)
        return json.loads(urllib.request.urlopen(req).read().decode())
    except Exception as e:
        print(f"[orch] POST error: {e}")
        return None

def api_patch(path, data):
    try:
        body = json.dumps(data).encode()
        req = urllib.request.Request(f"{api_url}{path}", data=body, headers=headers, method="PATCH")
        return json.loads(urllib.request.urlopen(req).read().decode())
    except Exception as e:
        print(f"[orch] PATCH error: {e}")
        return None

# Find first todo/backlog issue
try:
    issues = json.loads(issues_raw)
except:
    print("[orch] Failed to parse issues")
    sys.exit(0)

issue = None
for i in issues:
    if i.get("status") in ("todo", "backlog", "in_progress"):
        issue = i
        break

if not issue:
    print("[orch] No active issues")
    sys.exit(0)

issue_id = issue["id"]
title = issue.get("title", "")
desc = issue.get("description", "")
project_id = issue.get("projectId", "")

print(f"[orch] Issue: {title}")

# Check if sub-issues already exist via parentId filter
existing_children = api_get(f"/companies/{company_id}/issues?parentId={issue_id}") or []
has_children = len(existing_children) > 0
if has_children:
    print(f"[orch] Sub-issues already exist ({len(existing_children)}), skipping create, dispatching existing")

if not has_children:
    # --- LLM analyze ---
    prompt = f"""Analyze this issue and plan sub-tasks for a coding team.
The issue may use Kiro spec format (Requirements with User Stories + Acceptance Criteria using WHEN/THEN/SHALL).

ISSUE: {title}

DESCRIPTION:
{desc}

PARSING RULES:
- If description has "## Requirements" with "### Requirement N" sections: parse each requirement as a separate impl task
- Each requirement's "User Story" = task title, "Acceptance Criteria" (WHEN/THEN) = task goal (include ALL criteria)
- If description has "## Target" with Repo/Branch: extract repo SSH URL and branch
- If no Kiro format detected: analyze as free-text (legacy behavior)

Team has 3 phases that run in order:
Phase 1 — implementer: writes code (multiple tasks run PARALLEL)
Phase 2 — refactorer: cleans up code (runs after ALL impl done)
Phase 3 — reviewer: reviews code (runs after ALL refactor done)

Output ONLY valid JSON. Group ALL impl tasks first, then ALL refactor, then ALL review:
{{"repo": "git SSH URL (convert HTTPS to git@host:user/repo.git)", "branch": "from Target section", "phases": [{{"role": "implementer", "title": "[impl] R1: short summary", "goal": "User Story: ... \\nAcceptance Criteria:\\n1. WHEN ... THEN ...\\n2. WHEN ... THEN ..."}}, {{"role": "refactorer", "title": "[refactor] cleanup", "goal": "what to clean"}}, {{"role": "reviewer", "title": "[review] verify all acceptance criteria", "goal": "verify WHEN/THEN criteria from requirements"}}]}}
One impl task per Requirement. Keep total phases under 8. No thinking tags, no markdown."""

    llm_body = json.dumps({"model": model, "max_tokens": 2048, "temperature": 0.1, "messages": [{"role": "user", "content": prompt}]}).encode()
    req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", data=llm_body, headers={"Content-Type": "application/json", "Authorization": f"Bearer {or_key}"})

    try:
        resp = urllib.request.urlopen(req, timeout=60)
        content = json.loads(resp.read().decode())["choices"][0]["message"]["content"]
        content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
        content = re.sub(r"^```json\s*", "", content)
        content = re.sub(r"```$", "", content.strip())
        plan = json.loads(content)
        print(f"[orch] LLM plan: {len(plan.get('phases',[]))} phases")
    except Exception as e:
        print(f"[orch] LLM error: {e}")
        sys.exit(1)

    repo = plan.get("repo", "unknown")
    branch = plan.get("branch", "feat/task")
    phases = plan.get("phases", [])

    # Create sub-issues
    created = []
    for p in phases:
        d = {"title": p["title"], "description": p["goal"], "parentId": issue_id, "status": "todo"}
        if project_id:
            d["projectId"] = project_id
        result = api_post(f"/companies/{company_id}/issues", d)
        if result and "id" in result:
            created.append({"id": result["id"], "identifier": result.get("identifier", ""), "role": p["role"], "title": p["title"], "goal": p["goal"]})
            print(f"[orch] Created: {result.get('identifier','')} {p['title']}")

    if not created:
        print("[orch] No sub-issues created")
        sys.exit(1)
else:
    # Use existing sub-issues
    created = []
    repo = "unknown"
    branch = "feat/task"
    m = re.search(r"Repo:\s*(\S+)", desc)
    if m:
        repo = m.group(1)
        if "gitlab.com" in repo or "github.com" in repo:
            repo = re.sub(r"^https?://([^/]+)/", r"git@\1:", repo)
            if not repo.endswith(".git"):
                repo += ".git"
    m = re.search(r"Branch:\s*(\S+)", desc)
    if m:
        branch = m.group(1)
    for child in existing_children:
        if child.get("status") in ("done", "cancelled"):
            continue
        role = "implementer"
        t = child.get("title", "")
        if "[refactor]" in t: role = "refactorer"
        elif "[review]" in t: role = "reviewer"
        created.append({"id": child["id"], "identifier": child.get("identifier", ""), "role": role, "title": t, "goal": child.get("description", "")})

# Sort: impl first, then refactor, then review
role_order = {"implementer": 0, "refactorer": 1, "reviewer": 2}
created.sort(key=lambda c: role_order.get(c["role"], 9))

# --- Dispatch batch ---
if created:
    # Serial chain: each task depends on previous (safe for single branch)
    tasks, dep = [], []
    for c in created:
        tasks.append({"taskId": c["id"], "agentRole": c["role"], "dependsOn": list(dep), "title": c["title"], "goal": c["goal"], "scope": repo, "branch": branch, "identifier": c.get("identifier", "")})
        dep = [c["id"]]

    # Use Docker network URL for adapter callbacks (adapter in paperclip_net)
    adapter_api_url = api_url.replace("localhost", "paperclip").replace("127.0.0.1", "paperclip")
    batch = {"parentIssueId": issue_id, "paperclipApiUrl": adapter_api_url, "apiKey": api_key, "agentId": os.environ.get("PAPERCLIP_AGENT_ID",""), "companyId": company_id, "tasks": tasks}
    try:
        br = urllib.request.Request(f"{adapter_url}/batch", data=json.dumps(batch).encode(), headers={"Content-Type": "application/json"})
        print(f"[orch] Dispatch: {urllib.request.urlopen(br).read().decode()}")
    except Exception as e:
        print(f"[orch] Dispatch error: {e}")

    # Set parent in_progress
    api_patch(f"/issues/{issue_id}", {"status": "in_progress"})
    api_post(f"/issues/{issue_id}/comments", {"body": f"Dispatched {len(created)} sub-tasks"})
    print(f"[orch] Done. {issue_id} -> in_progress")
else:
    print("[orch] Nothing to dispatch")
PYEOF
