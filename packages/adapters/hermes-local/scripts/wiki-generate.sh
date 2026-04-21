#!/bin/bash
# wiki-generate.sh — Clone target repo → analyze with LLM → generate wiki docs → push
#
# Usage: bash wiki-generate.sh <REPO_SSH_URL> <PROJECT_NAME> [BRANCH]
#
# Env vars required:
#   OPENROUTER_API_KEY — for LLM analysis
#   GITLAB_TOKEN — for MR creation (optional)
#
# Output: docs written to /workspace/wiki/docs/<PROJECT_NAME>/

set -euo pipefail

REPO_URL="${1:?Usage: wiki-generate.sh <REPO_SSH_URL> <PROJECT_NAME> [BRANCH]}"
PROJECT_NAME="${2:?Usage: wiki-generate.sh <REPO_SSH_URL> <PROJECT_NAME> [BRANCH]}"
BRANCH="${3:-main}"
OPENROUTER_KEY="${OPENROUTER_API_KEY:-}"
LLM_MODEL="${LLM_MODEL:-qwen/qwen3-coder}"
WIKI_DIR="/workspace/wiki"
REPOS_DIR="/workspace/repos"

[ -z "$OPENROUTER_KEY" ] && echo "[wiki] No OPENROUTER_API_KEY" && exit 1

echo "[wiki] Target: $REPO_URL ($BRANCH)"
echo "[wiki] Project: $PROJECT_NAME"

# ─── Step 1: Clone/pull target repo ───
mkdir -p "$REPOS_DIR"
TARGET_DIR="$REPOS_DIR/$PROJECT_NAME"

if [ -d "$TARGET_DIR/.git" ]; then
  echo "[wiki] Pulling latest $TARGET_DIR ..."
  git -C "$TARGET_DIR" checkout "$BRANCH" 2>/dev/null || true
  git -C "$TARGET_DIR" pull --rebase --quiet || true
else
  echo "[wiki] Cloning $REPO_URL → $TARGET_DIR ..."
  git clone -b "$BRANCH" "$REPO_URL" "$TARGET_DIR"
fi

# ─── Step 2: Collect codebase context ───
echo "[wiki] Analyzing codebase..."

CONTEXT=""

# Project structure
CONTEXT+="## Project Structure\n"
CONTEXT+="$(cd "$TARGET_DIR" && tree -L 3 -I 'vendor|node_modules|.git|dist|build|__pycache__' 2>/dev/null || find . -maxdepth 3 -type f | head -100)\n\n"

# Key files content (truncated)
for f in README.md AGENT.md go.mod package.json requirements.txt docker-compose.yml Dockerfile Makefile; do
  if [ -f "$TARGET_DIR/$f" ]; then
    CONTEXT+="## $f\n"
    CONTEXT+="$(head -80 "$TARGET_DIR/$f")\n\n"
  fi
done

# Entry points
for d in cmd internal pkg src app lib api; do
  if [ -d "$TARGET_DIR/$d" ]; then
    CONTEXT+="## $d/ structure\n"
    CONTEXT+="$(cd "$TARGET_DIR" && find "$d" -maxdepth 2 -name '*.go' -o -name '*.ts' -o -name '*.py' | head -30)\n\n"
  fi
done

# API routes (grep for common patterns)
ROUTES=$(cd "$TARGET_DIR" && grep -rn 'router\.\|\.GET\|\.POST\|\.PUT\|\.DELETE\|@app\.\|@router\.' --include='*.go' --include='*.ts' --include='*.py' 2>/dev/null | head -30 || true)
if [ -n "$ROUTES" ]; then
  CONTEXT+="## API Routes Found\n$ROUTES\n\n"
fi

# Kafka topics (if any)
KAFKA=$(cd "$TARGET_DIR" && grep -rn 'topic\|kafka\|consumer\|producer' --include='*.go' --include='*.ts' --include='*.yaml' -i 2>/dev/null | head -20 || true)
if [ -n "$KAFKA" ]; then
  CONTEXT+="## Kafka References\n$KAFKA\n\n"
fi

# ─── Step 3: LLM generate docs ───
echo "[wiki] Generating docs with LLM ($LLM_MODEL)..."

PROMPT="Analyze this codebase and generate wiki documentation.

PROJECT: $PROJECT_NAME
REPO: $REPO_URL
BRANCH: $BRANCH

CODEBASE CONTEXT:
$CONTEXT

Generate 3 sections separated by '---SPLIT---':

SECTION 1 — AGENT.md (codebase guide for AI coding agents):
- Overview, Tech Stack (with versions), Project Structure, Key Patterns, Build & Run, Common Tasks

SECTION 2 — service.md (wiki entry):
- Overview, Architecture, API Endpoints (with request/response), Dependencies, Data Models, Deployment

SECTION 3 — contracts.md (API contracts):
- REST API routes with schemas, gRPC protos (if any), Kafka topics + message schemas (if any)
- If no contracts found, write 'No contracts detected.' and skip details.

Rules:
- Be concise. Max 60 lines per section.
- Use real examples from the code, not generic placeholders.
- Include version numbers from go.mod/package.json.
- For Go projects: describe hexagonal layers if present.
- Output raw markdown only, no code fences around the sections."

LLM_BODY=$(python3 -c "
import json, sys
prompt = sys.stdin.read()
print(json.dumps({'model': '$LLM_MODEL', 'max_tokens': 4096, 'temperature': 0.1, 'messages': [{'role': 'user', 'content': prompt}]}))
" <<< "$PROMPT")

RESPONSE=$(curl -s -X POST "https://openrouter.ai/api/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENROUTER_KEY" \
  -d "$LLM_BODY" --max-time 120)

CONTENT=$(echo "$RESPONSE" | python3 -c "
import json, sys, re
data = json.load(sys.stdin)
content = data['choices'][0]['message']['content']
content = re.sub(r'<think>.*?</think>', '', content, flags=re.DOTALL).strip()
print(content)
")

# ─── Step 4: Split and write docs ───
echo "[wiki] Writing docs to $WIKI_DIR/docs/$PROJECT_NAME/ ..."
mkdir -p "$WIKI_DIR/docs/$PROJECT_NAME"

python3 << PYEOF
import sys

content = """$CONTENT"""
parts = content.split('---SPLIT---')

files = ['AGENT.md', 'service.md', 'contracts.md']
for i, part in enumerate(parts):
    if i < len(files):
        part = part.strip()
        if part and 'No contracts detected' not in part or i < 2:
            with open(f'$WIKI_DIR/docs/$PROJECT_NAME/{files[i]}', 'w') as f:
                f.write(part + '\n')
            print(f'[wiki] Written: docs/$PROJECT_NAME/{files[i]}')
PYEOF

# ─── Step 5: Commit and push wiki ───
echo "[wiki] Pushing to wiki repo..."
cd "$WIKI_DIR"
git checkout staging 2>/dev/null || git checkout -b staging origin/staging 2>/dev/null || git checkout -b staging

git add "docs/$PROJECT_NAME/"
if git diff --cached --quiet; then
  echo "[wiki] No changes to commit"
else
  git commit -m "docs($PROJECT_NAME): generate wiki documentation"
  git push origin staging
  echo "[wiki] Pushed to staging branch"
fi

# ─── Step 6: Create MR (if gitlab-api.sh exists and GITLAB_TOKEN set) ───
if [ -n "${GITLAB_TOKEN:-}" ] && [ -f /root/gitlab-api.sh ]; then
  bash /root/gitlab-api.sh "$PROJECT_NAME"
fi

echo "[wiki] Done: $PROJECT_NAME"
