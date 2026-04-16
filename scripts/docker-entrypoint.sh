#!/bin/sh
set -e

# Capture runtime UID/GID from environment variables, defaulting to 1000
PUID=${USER_UID:-1000}
PGID=${USER_GID:-1000}

# Adjust the node user's UID/GID if they differ from the runtime request
# and fix volume ownership only when a remap is needed
changed=0

if [ "$(id -u node)" -ne "$PUID" ]; then
    echo "Updating node UID to $PUID"
    usermod -o -u "$PUID" node
    changed=1
fi

if [ "$(id -g node)" -ne "$PGID" ]; then
    echo "Updating node GID to $PGID"
    groupmod -o -g "$PGID" node
    usermod -g "$PGID" node
    changed=1
fi

if [ "$changed" = "1" ]; then
    chown -R node:node /paperclip
fi

# Patch hermes adapter after plugin install (plugins install after server start)
# Fixes:
#   1. localhost/127.0.0.1 → container hostname for Docker networking
#   2. Operator precedence bug: ternary without parens makes PAPERCLIP_API_URL unusable
PATCH_TARGET="${PAPERCLIP_ADAPTER_HOST:-paperclip:3100}"
(
  sleep 30
  while true; do
    find /paperclip /app -path "*/hermes-paperclip-adapter/dist/server/execute.js" 2>/dev/null | while read f; do
      patched=0
      # Fix hardcoded localhost URLs
      if grep -q "127.0.0.1:3100" "$f" 2>/dev/null; then
        sed -i "s|http://127.0.0.1:3100/api|http://${PATCH_TARGET}/api|g" "$f"
        sed -i "s|http://localhost:3100/api|http://${PATCH_TARGET}/api|g" "$f"
        patched=1
      fi
      # Fix operator precedence bug on the API URL ternary:
      #   Original: cfgString(...) || process.env.PAPERCLIP_API_URL || process.env.X ? "http://"+X+"/api" : fallback
      #   Fixed:    cfgString(...) || process.env.PAPERCLIP_API_URL || (process.env.X ? "http://"+X+"/api" : fallback)
      if grep -q 'process\.env\.PAPERCLIP_ADAPTER_HOST ? "http://"' "$f" 2>/dev/null; then
        sed -i 's|process\.env\.PAPERCLIP_ADAPTER_HOST ? "http://" + process\.env\.PAPERCLIP_ADAPTER_HOST + "/api" : "http://paperclip:3100/api"|(process.env.PAPERCLIP_ADAPTER_HOST ? "http://" + process.env.PAPERCLIP_ADAPTER_HOST + "/api" : "http://'"${PATCH_TARGET}"'/api")|g' "$f"
        patched=1
      fi
      if [ "$patched" = "1" ]; then
        echo "[entrypoint] Patched hermes adapter execute.js → ${PATCH_TARGET}"
      fi
    done
    sleep 60
  done
) &

exec gosu node "$@"
