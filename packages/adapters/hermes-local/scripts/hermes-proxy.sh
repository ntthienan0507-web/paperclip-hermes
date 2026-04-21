#!/usr/bin/env bash
# Paperclip gọi "hermes" → proxy forward vào hermes container
# Strip -m/--model + --provider flags (dùng config trong container)
# Forward PAPERCLIP_* env vars so hermes can auth with Paperclip API
args=()
skip_next=false
for arg in "$@"; do
  if $skip_next; then skip_next=false; continue; fi
  case "$arg" in -m|--model|--provider|-r|--resume) skip_next=true; continue ;; esac
  args+=("$arg")
done

# Build -e flags to forward Paperclip env vars through docker exec
env_flags=()
for var in PAPERCLIP_API_KEY PAPERCLIP_AGENT_ID PAPERCLIP_COMPANY_ID PAPERCLIP_API_URL PAPERCLIP_RUN_ID PAPERCLIP_TASK_ID; do
  [ -n "${!var}" ] && env_flags+=(-e "${var}=${!var}")
done

exec docker exec -i "${env_flags[@]}" hermes-orch hermes "${args[@]}" --yolo -t terminal
