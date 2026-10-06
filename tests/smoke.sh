#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
export CLAUDE_PORTABLE_BIN="$REPO/tests/fake-claude.sh"
chmod +x "$CLAUDE_PORTABLE_BIN"

fails=0
pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
lines() { wc -l <"$1" | tr -d ' '; }
launch() { local at="$1"; shift; "$BASH" "$T/$at/drive/system/claude-portable.sh" "$T/$at/drive/Projects/App" "$@" >/dev/null; }
session_dir() { ls -d "$T/$1/drive/data/projects/"*"-$1-drive-Projects-App" 2>/dev/null | head -1; }
newest() { ls -t "$1"/*.jsonl | head -1; }
has_transcript() { local f; for f in "$1"/*.jsonl; do [ "$(lines "$f")" = "$2" ] && return 0; done; return 1; }

mkdir -p "$T/a/drive/Projects/App" "$T/b" "$T/c"
cp -R "$REPO/system" "$T/a/drive/"
D="$T/a/drive/data"

echo "First computer"
launch a --new
A="$(session_dir a)"
check "creates a session folder named after the path" test -n "$A"
check "starts a conversation" test "$(lines "$(newest "$A")")" = 1
check "passes --system-prompt-snapshot off and the context file" grep -q -- '--system-prompt-snapshot off --append-system-prompt-file' "$D/fake-claude.log"
check "seeds the /handoff command" test -f "$D/commands/handoff.md"
touch "$A/._resource-fork.jsonl"

echo "Second computer"
mv "$T/a/drive" "$T/b/drive"; D="$T/b/drive/data"
launch b --continue
B="$(session_dir b)"
check "brings the conversation over and continues it" test "$(lines "$(newest "$B")")" = 2
check "skips macOS resource-fork files" test ! -e "$B/._resource-fork.jsonl"
check "tells Claude where the project lived before" grep -q "$T/a/drive/Projects/App" "$D/portable/run/App.md"
check "passes --continue" grep -q -- '--continue' "$D/fake-claude.log"
check "remembers both paths" test "$(grep -c . "$D/portable/projects/App.tsv")" = 2

echo "Back on the first computer"
printf 'Build the Swift target on macOS next.\n' >"$D/portable/handoff/App.md"
mv "$T/b/drive" "$T/a/drive"; D="$T/a/drive/data"
launch a --continue
check "picks up what happened on the second computer" test "$(lines "$(newest "$A")")" = 3
check "includes the handoff note in the context" grep -q 'Build the Swift target' "$D/portable/run/App.md"

echo "A computer where Claude Code stores the session somewhere unexpected"
mv "$T/a/drive" "$T/c/drive"; D="$T/c/drive/data"
FAKE_CLAUDE_DIR=elsewhere launch c --new
check "learns the real session folder" grep -q $'^elsewhere\t' "$D/portable/projects/App.tsv"
check "forgets the predicted one" test -z "$(grep -- '-c-drive-Projects-App' "$D/portable/projects/App.tsv" || true)"
check "copies the history into the real folder" has_transcript "$D/projects/elsewhere" 3
FAKE_CLAUDE_DIR=elsewhere launch c --continue
check "continues there on the next launch" test "$(tail -1 "$D/fake-claude.log" | grep -c -- '--continue')" = 1

echo "The project menu"
mkdir -p "$T/c/drive/Projects/Beta" "$T/outside"
menu() { (cd "$T" && CLAUDE_PORTABLE_KEYS="$1" "$BASH" "$T/c/drive/system/claude-portable.sh" >/dev/null); }
last_is() { case "$(tail -1 "$D/fake-claude.log")" in $1) return 0 ;; esac; return 1; }
last_isnt() { ! last_is "$1"; }
menu "enter"
check "enter continues the most recent project" last_is "*/Projects/App | *--continue*"
menu "down n"
check "arrows move to the next project" last_is "*/Projects/Beta | *"
check "n starts a new conversation" last_isnt "*--continue*"
menu "+ text=Gamma"
check "+ creates a project" test -d "$T/c/drive/Projects/Gamma"
check "and opens it" last_is "*/Projects/Gamma | *"
menu "o text=$T/outside"
check "o opens a folder on this computer" last_is "*/outside | *"
count="$(grep -c . "$D/fake-claude.log")"
menu "q"
check "q quits without opening anything" test "$(grep -c . "$D/fake-claude.log")" = "$count"

echo "Command line"
check "--help prints usage" "$BASH" -c "'$BASH' '$T/c/drive/system/claude-portable.sh' --help | grep -q '^Usage:'"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "All checks passed"
