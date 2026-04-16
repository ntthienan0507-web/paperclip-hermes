#!/bin/bash
# dispatch.sh — Dispatch batch to adapter
# Usage: dispatch.sh <issueId> <title> <goal> <repo> <branch>
ISSUE_ID="$1"
TITLE="$2"
GOAL="$3"
REPO="$4"
BRANCH="$5"
API_URL="${PAPERCLIP_API_URL:-http://paperclip:3100/api}"
API_KEY="${PAPERCLIP_API_KEY:-}"

python3 -c "
import json, sys, urllib.request

issue_id, title, goal, repo, branch = sys.argv[1:6]
api_url, api_key = sys.argv[6], sys.argv[7]

batch = {
    'parentIssueId': issue_id,
    'paperclipApiUrl': api_url,
    'apiKey': api_key,
    'tasks': [
        {'taskId': f'{issue_id}-impl', 'agentRole': 'implementer', 'dependsOn': [], 'title': f'[impl] {title}', 'goal': goal, 'scope': repo, 'branch': branch},
        {'taskId': f'{issue_id}-refactor', 'agentRole': 'refactorer', 'dependsOn': [f'{issue_id}-impl'], 'title': f'[refactor] {title}', 'goal': 'Review and clean up the implementation', 'scope': repo, 'branch': branch},
        {'taskId': f'{issue_id}-review', 'agentRole': 'reviewer', 'dependsOn': [f'{issue_id}-refactor'], 'title': f'[review] {title}', 'goal': 'Review code quality, run tests, verify acceptance criteria', 'scope': repo, 'branch': branch},
    ]
}

data = json.dumps(batch).encode()
req = urllib.request.Request('http://localhost:8650/batch', data=data, headers={'Content-Type': 'application/json'})
resp = urllib.request.urlopen(req)
print(resp.read().decode())
" "$ISSUE_ID" "$TITLE" "$GOAL" "$REPO" "$BRANCH" "$API_URL" "$API_KEY"
