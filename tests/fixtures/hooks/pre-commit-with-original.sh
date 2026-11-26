#!/bin/sh
# --- BEGIN CTX-KIT GIT-SYNC HOOK ---
ctx_original_hook="$(dirname "$0")/pre-commit.ctx-kit-original"
if [ ! -e "$ctx_original_hook" ] && [ ! -L "$ctx_original_hook" ]; then
  echo "Error: original pre-commit hook is missing: $ctx_original_hook" >&2
  exit 1
fi
if [ -x "$ctx_original_hook" ]; then
  "$ctx_original_hook" "$@"
  ctx_original_status=$?
  if [ "$ctx_original_status" -ne 0 ]; then
    exit "$ctx_original_status"
  fi
fi
if [ -f "ctx.sh" ]; then
  bash ctx.sh _hook_run_pre_commit
elif [ -f "scripts/ctx.sh" ]; then
  bash scripts/ctx.sh _hook_run_pre_commit
fi
# --- END CTX-KIT GIT-SYNC HOOK ---
