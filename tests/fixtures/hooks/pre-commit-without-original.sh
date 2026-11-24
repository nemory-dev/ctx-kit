#!/bin/sh
# --- BEGIN CTX-KIT GIT-SYNC HOOK ---
ctx_original_hook="$(dirname "$0")/pre-commit.ctx-kit-original"
if [ -e "$ctx_original_hook" ] || [ -L "$ctx_original_hook" ]; then
  echo "Error: unexpected pre-commit hook backup: $ctx_original_hook" >&2
  exit 1
fi
if [ -f "ctx.sh" ]; then
  bash ctx.sh _hook_run_pre_commit
elif [ -f "scripts/ctx.sh" ]; then
  bash scripts/ctx.sh _hook_run_pre_commit
fi
# --- END CTX-KIT GIT-SYNC HOOK ---
