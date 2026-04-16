#!/usr/bin/env bash
# Paperclip gọi "hermes" → proxy forward vào hermes-orch container
# Strip -m/--model + --provider flags (dùng config trong container)
args=()
skip_next=false
for arg in "$@"; do
  if $skip_next; then skip_next=false; continue; fi
  case "$arg" in -m|--model|--provider) skip_next=true; continue ;; esac
  args+=("$arg")
done
exec docker exec -i hermes-orch hermes "${args[@]}"
