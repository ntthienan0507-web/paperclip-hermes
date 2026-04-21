#!/bin/bash
# auto-dispatch-wiki.sh — Fetch wiki issue → LLM analyze → create sub-issues → dispatch to wiki-trainer
# Variant of auto-dispatch.sh specialized for wiki generation tasks

API_URL="${PAPERCLIP_API_URL:-http://localhost:3100/api}"
API_KEY="${PAPERCLIP_API_KEY:-}"
AGENT_ID="${PAPERCLIP_AGENT_ID:-}"
COMPANY_ID="${PAPERCLIP_COMPANY_ID:-}"
ADAPTER_URL="${ADAPTER_URL:-http://localhost:8650}"
OPENROUTER_KEY="${OPENROUTER_API_KEY:-}"
LLM_MODEL="${LLM_MODEL:-qwen/qwen3-coder}"

[ -z "$API_KEY" ] && echo "[wiki-orch] No API_KEY" && exit 1
[ -z "$COMPANY_ID" ] && echo "[wiki-orch] No COMPANY_ID" && exit 1

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
        print(f"[wiki-orch] GET error: {e}")
        return None

def api_post(path, data):
    try:
        body = json.dumps(data).encode()
        req = urllib.request.Request(f"{api_url}{path}", data=body, headers=headers)
        return json.loads(urllib.request.urlopen(req).read().decode())
    except Exception as e:
        print(f"[wiki-orch] POST error: {e}")
        return None

def api_patch(path, data):
    try:
        body = json.dumps(data).encode()
        req = urllib.request.Request(f"{api_url}{path}", data=body, headers=headers, method="PATCH")
        return json.loads(urllib.request.urlopen(req).read().decode())
    except Exception as e:
        print(f"[wiki-orch] PATCH error: {e}")
        return None

# Find first todo/backlog issue
try:
    issues = json.loads(issues_raw)
except:
    print("[wiki-orch] Failed to parse issues")
    sys.exit(0)

issue = None
for i in issues:
    if i.get("status") in ("todo", "backlog", "in_progress"):
        issue = i
        break

if not issue:
    print("[wiki-orch] No active issues")
    sys.exit(0)

issue_id = issue["id"]
title = issue.get("title", "")
desc = issue.get("description", "")
project_id = issue.get("projectId", "")

print(f"[wiki-orch] Issue: {title}")

# Check if sub-issues already exist
existing_children = api_get(f"/companies/{company_id}/issues?parentId={issue_id}") or []
has_children = len(existing_children) > 0
if has_children:
    print(f"[wiki-orch] Sub-issues exist ({len(existing_children)}), dispatching existing")

if not has_children:
    # --- LLM analyze for wiki generation ---
    prompt = f"""Analyze this wiki generation issue and plan sub-tasks for a wiki-trainer agent.
The issue uses Kiro spec format with Requirements + Acceptance Criteria.

ISSUE: {title}

DESCRIPTION:
{desc}

PARSING RULES:
- Extract target repo SSH URL and branch from "## Target" section
- Extract wiki repo URL from "## Wiki Repo" section (default: git@gitlab.com:quocchung.nguyen/go-engineering-wiki.git)
- Parse "## Requirements" → each "### Requirement N" becomes a wiki-trainer task

Wiki-trainer has 3 phases that run in order:
Phase 1 — wiki-trainer: analyze codebase + generate docs (one task per requirement)
  - Each task: clone repo → analyze specific aspect → generate/update doc
  - Task types: AGENT.md (codebase guide), service.md (wiki entry), contracts.md (API contracts)
Phase 2 — wiki-trainer: push docs + create MRs (runs after ALL generation done)
Phase 3 — wiki-trainer: verify MRs + report back (runs after push done)

Output ONLY valid JSON:
{{"repo": "target git SSH URL", "branch": "main or develop", "wiki_repo": "wiki git SSH URL", "phases": [{{"role": "wiki-trainer", "title": "[generate] R1: AGENT.md for project-name", "goal": "User Story: ...\\nAcceptance Criteria:\\n1. WHEN ... THEN ...\\nOutput: AGENT.md"}}, {{"role": "wiki-trainer", "title": "[generate] R2: service.md wiki entry", "goal": "..."}}, {{"role": "wiki-trainer", "title": "[push] create MRs for generated docs", "goal": "Push AGENT.md to target repo (feature branch), wiki docs to wiki repo (staging branch), create GitLab MRs"}}, {{"role": "wiki-trainer", "title": "[verify] check MRs and report", "goal": "Verify MRs created, post links to parent issue"}}]}}
One generate task per Requirement. Keep total phases under 6. No thinking tags, no markdown."""

    llm_body = json.dumps({"model": model, "max_tokens": 2048, "temperature": 0.1, "messages": [{"role": "user", "content": prompt}]}).encode()
    req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", data=llm_body, headers={"Content-Type": "application/json", "Authorization": f"Bearer {or_key}"})

    try:
        resp = urllib.request.urlopen(req, timeout=60)
        content = json.loads(resp.read().decode())["choices"][0]["message"]["content"]
        content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
        content = re.sub(r"^```json\s*", "", content)
        content = re.sub(r"```$", "", content.strip())
        plan = json.loads(content)
        print(f"[wiki-orch] LLM plan: {len(plan.get('phases',[]))} phases")
    except Exception as e:
        print(f"[wiki-orch] LLM error: {e}")
        sys.exit(1)

    repo = plan.get("repo", "unknown")
    branch = plan.get("branch", "main")
    wiki_repo = plan.get("wiki_repo", "git@gitlab.com:quocchung.nguyen/go-engineering-wiki.git")
    phases = plan.get("phases", [])

    # Create sub-issues
    created = []
    for p in phases:
        goal_with_context = p["goal"]
        # Append wiki repo info to push/verify tasks
        if "[push]" in p["title"] or "[verify]" in p["title"]:
            goal_with_context += f"\n\nTarget repo: {repo}\nWiki repo: {wiki_repo}\nBranch: {branch}"

        d = {"title": p["title"], "description": goal_with_context, "parentId": issue_id, "status": "todo"}
        if project_id:
            d["projectId"] = project_id
        result = api_post(f"/companies/{company_id}/issues", d)
        if result and "id" in result:
            created.append({"id": result["id"], "identifier": result.get("identifier", ""), "role": p["role"], "title": p["title"], "goal": goal_with_context})
            print(f"[wiki-orch] Created: {result.get('identifier','')} {p['title']}")

    if not created:
        print("[wiki-orch] No sub-issues created")
        sys.exit(1)
else:
    # Use existing sub-issues
    created = []
    repo = "unknown"
    branch = "main"
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
        created.append({"id": child["id"], "identifier": child.get("identifier", ""), "role": "wiki-trainer", "title": child.get("title", ""), "goal": child.get("description", "")})

# --- Dispatch batch ---
if created:
    # Serial chain: each task depends on previous
    tasks, dep = [], []
    for c in created:
        tasks.append({"taskId": c["id"], "agentRole": c["role"], "dependsOn": list(dep), "title": c["title"], "goal": c["goal"], "scope": repo, "branch": branch, "identifier": c.get("identifier", "")})
        dep = [c["id"]]

    # Use Docker network URL for adapter callbacks
    adapter_api_url = api_url.replace("localhost", "paperclip").replace("127.0.0.1", "paperclip")
    batch = {"parentIssueId": issue_id, "paperclipApiUrl": adapter_api_url, "apiKey": api_key, "agentId": os.environ.get("PAPERCLIP_AGENT_ID",""), "companyId": company_id, "tasks": tasks}
    try:
        br = urllib.request.Request(f"{adapter_url}/batch", data=json.dumps(batch).encode(), headers={"Content-Type": "application/json"})
        print(f"[wiki-orch] Dispatch: {urllib.request.urlopen(br).read().decode()}")
    except Exception as e:
        print(f"[wiki-orch] Dispatch error: {e}")

    # Set parent in_progress
    api_patch(f"/issues/{issue_id}", {"status": "in_progress"})
    api_post(f"/issues/{issue_id}/comments", {"body": f"Wiki generation dispatched: {len(created)} sub-tasks"})
    print(f"[wiki-orch] Done. {issue_id} -> in_progress")
else:
    print("[wiki-orch] Nothing to dispatch")
PYEOF
