#!/bin/bash
set -euo pipefail
dir="$CLAUDE_CONFIG_DIR/projects/${FAKE_CLAUDE_DIR:-$(pwd -P | sed 's/[^a-zA-Z0-9]/-/g')}"
mkdir -p "$dir"
printf '%s | %s\n' "$(pwd -P)" "$*" >>"$CLAUDE_CONFIG_DIR/fake-claude.log"

file=""
case " $* " in *" --continue "*) file="$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1 || true)" ;; esac
[ -n "$file" ] || file="$dir/$(date +%s)-$$-$RANDOM.jsonl"
printf '{"type":"user","cwd":"%s"}\n' "$(pwd -P)" >>"$file"
