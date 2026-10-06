#!/bin/bash
set -euo pipefail
export LC_ALL=en_US.UTF-8 2>/dev/null || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DATA="$ROOT/data"
PORTABLE="$DATA/portable"
PROJECTS_DIR="$ROOT/Projects"
case "$(uname -s)" in
  Darwin) OS_NAME="macOS"; os=darwin ;;
  *)      OS_NAME="$(uname -s)"; os=linux ;;
esac
case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=x64 ;; esac
[ "$os" = darwin ] && [ "$arch" = x64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ] && arch=arm64
PLAT="$os-$arch"
HOST="$(hostname -s 2>/dev/null || hostname)"

usage() {
  cat <<'EOF'
Usage:
  claude-portable [PROJECT_DIR] [--new | --continue | --resume] [--name NAME] [-- CLAUDE_ARGS...]
  claude-portable --import DIR [--name NAME]

  PROJECT_DIR   Project to open. Without it you get the project menu.
  --new         Start a new conversation.
  --continue    Continue the most recent conversation (the default when one exists).
  --resume      Pick a conversation from a list.
  --name NAME   Project name used to match this folder across computers (default: folder name).
  --import DIR  Copy this computer's existing Claude Code history for DIR onto the drive.
  --            Everything after it is passed to claude unchanged.

Environment:
  CLAUDE_PORTABLE_BIN   Use this claude executable instead of the one in bin/.
  NO_COLOR              Turn colours off.
EOF
}

encode() { printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'; }
key_of() {
  local s="$1"
  [ "$os" = darwin ] && s="$(printf '%s' "$1" | iconv -f UTF-8-MAC -t UTF-8 2>/dev/null || printf '%s' "$1")"
  printf '%s' "$s" | sed 's/[^A-Za-z0-9._-]/_/g'
}
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
fsize() { wc -c <"$1" | tr -d ' '; }

sync_dir() {
  local src="$1" dst="$2" n=0 rel s d
  [ -d "$src" ] || { echo 0; return; }
  while IFS= read -r rel; do
    rel="${rel#./}"; s="$src/$rel"; d="$dst/$rel"
    if [ ! -e "$d" ] || { case "$rel" in *.jsonl) [ "$(fsize "$s")" -gt "$(fsize "$d")" ] ;; *) [ "$s" -nt "$d" ] ;; esac; }; then
      mkdir -p "$(dirname "$d")"
      cp -p "$s" "$d" 2>/dev/null || cp "$s" "$d"
      n=$((n + 1))
    fi
  done < <(cd "$src" && find . -type f ! -name '._*' ! -name '.DS_Store')
  echo "$n"
}

alias_file() { echo "$PORTABLE/projects/$1.tsv"; }

session_dirs() { local d; for d in "$DATA/projects"/*/; do [ -d "$d" ] && basename "$d"; done; return 0; }

save_alias() {
  local f; f="$(alias_file "$1")"
  mkdir -p "$PORTABLE/projects"
  { [ -f "$f" ] && awk -F'\t' -v e="$2" -v x="${4:-}" '$1 != e && $1 != x && NF' "$f"; printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$OS_NAME" "$HOST" "$(now)"; } >"$f.tmp"
  mv "$f.tmp" "$f"
}

toolchains() {
  local t out=""
  for t in git swift node python3 dotnet cargo go java; do
    command -v "$t" >/dev/null 2>&1 && out="$out${out:+, }$t"
  done
  if xcode-select -p 2>/dev/null | grep -q '\.app/'; then
    out="$out${out:+, }xcodebuild ($(xcodebuild -version 2>/dev/null | head -1))"
  fi
  echo "${out:-(none detected)}"
}

if { [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; } || [ -n "${FORCE_COLOR:-}" ]; then
  RESET=$'\e[0m' BOLD=$'\e[1m' DIM=$'\e[38;5;245m' ACCENT=$'\e[38;5;209m'
else
  RESET="" BOLD="" DIM="" ACCENT=""
fi
if [ -t 1 ]; then
  CLEAR=$'\e[H\e[J' HIDE_CURSOR=$'\e[?25l' SHOW_CURSOR=$'\e[?25h'
  trap 'printf "%s" "$SHOW_CURSOR"' EXIT
else
  CLEAR="" HIDE_CURSOR="" SHOW_CURSOR=""
fi

SCRIPTED="${CLAUDE_PORTABLE_KEYS+yes}"
SCRIPTED_KEYS="${CLAUDE_PORTABLE_KEYS:-}"
next_key() {
  if [ -n "$SCRIPTED" ]; then
    SCRIPTED_KEYS="${SCRIPTED_KEYS# }"
    KEY="${SCRIPTED_KEYS%% *}"; SCRIPTED_KEYS="${SCRIPTED_KEYS#"$KEY"}"
    [ -n "$KEY" ] || KEY=q
    return 0
  fi
  local c="" rest=""
  IFS= read -rsn1 c </dev/tty || c=q
  case "$c" in
    $'\e') IFS= read -rsn2 -t 1 rest </dev/tty || true
           case "$rest" in '[A'|OA) KEY=up ;; '[B'|OB) KEY=down ;; *) KEY=esc ;; esac ;;
    '') KEY=enter ;;
    *) KEY="$c" ;;
  esac
}

read_text() {
  if [ -n "$SCRIPTED" ]; then next_key; TEXT="${KEY#text=}"; [ "$KEY" != q ] || TEXT=""; return 0; fi
  printf '\n  %s%s%s %s' "$BOLD" "$1" "$RESET" "$SHOW_CURSOR"
  IFS= read -r TEXT </dev/tty || TEXT=""
  printf '%s' "$HIDE_CURSOR"
}

fit() {
  local s="$2" w="$3" pad
  [ "$w" -gt 1 ] || w=1
  [ "${#s}" -le "$w" ] || s="${s:0:$((w - 1))}…"
  printf -v pad '%*s' $((w - ${#s})) ''
  printf -v "$1" '%s%s' "$s" "$pad"
}
short_path() {
  local p="$2" first rest tail
  if [ "${#p}" -gt "$3" ]; then
    first="${p%%/*}"; rest="${p#*/}"; tail="${rest##*/}"; rest="${rest%/*}"
    [ "$rest" = "$tail" ] || tail="${rest##*/}/$tail"
    p="$first/…/$tail"
  fi
  printf -v "$1" '%s' "$p"
}
hint() { printf '%s%s%s %s%s%s' "$BOLD" "$1" "$RESET" "$DIM" "$2" "$RESET"; }
HINTS_LIST="  $(hint '↑↓' choose)   $(hint enter continue)   $(hint n 'new chat')"
HINTS_ALWAYS="  $(hint + 'new project')   $(hint o 'open folder')   $(hint u update)   $(hint q quit)"

if [ "$os" = darwin ]; then
  epoch_of() { date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || true; }
  day_of() { date -r "$1" "+$2"; }
else
  epoch_of() { date -u -d "$1" +%s 2>/dev/null || true; }
  day_of() { date -d "@$1" "+$2"; }
fi
when_of() {
  local t d; t="$(epoch_of "$1")"; [ -n "$t" ] || return 0
  d="$(day_of "$t" %Y%m%d)"
  if [ "$d" = "$(date +%Y%m%d)" ]; then echo today
  elif [ "$d" = "$(day_of $(($(date +%s) - 86400)) %Y%m%d)" ]; then echo yesterday
  elif [ "${d:0:4}" = "$(date +%Y)" ]; then day_of "$t" '%b %e' | tr -s ' '
  else day_of "$t" '%b %e, %Y' | tr -s ' '; fi
}

load_projects() {
  local rows="" d n f last ts path where p_os when tilde="~" us=$'\x1f' nl=$'\n' tab=$'\t'
  for d in "$PROJECTS_DIR"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; n="$(basename "$d")"; f="$(alias_file "$(key_of "$n")")"; last=""
    [ -f "$f" ] && last="$(sort -t "$tab" -k5 "$f" | tail -1)"
    rows="$rows$(printf '%s' "$last" | cut -f5)$us$n$us$d$us$(printf '%s' "$last" | cut -f3)$nl"
  done
  for f in "$PORTABLE"/projects/*.tsv; do
    [ -f "$f" ] || continue
    while IFS="$tab" read -r _ path p_os _ ts; do
      if [ "$p_os" != "$OS_NAME" ] || [ ! -d "$path" ]; then continue; fi
      case "$path/" in "$PROJECTS_DIR"/*) continue ;; esac
      short_path where "${path/#"$HOME"/$tilde}" 40
      rows="$rows$ts$us$(basename "$path")$us$path$us@$where$nl"
    done <"$f"
  done
  NAMES=(); PATHS=(); DETAILS=()
  while IFS="$us" read -r ts n path where; do
    [ -n "$n" ] || continue
    when=""; [ -z "$ts" ] || when="$(when_of "$ts")"
    case "$where" in
      @*) DETAILS+=("${where#@}${when:+ · $when}") ;;
      "") DETAILS+=("not opened yet") ;;
      *) DETAILS+=("$where · $when") ;;
    esac
    NAMES+=("$n"); PATHS+=("$path")
  done < <(printf '%s' "$rows" | sort -t "$us" -k1,1r | awk -F "$us" 'NF && !seen[$3]++')
}

measure() {
  local c i=0
  c="$(tput cols 2>/dev/null || echo 80)"; [ "$c" -le 84 ] || c=84; [ "$c" -ge 50 ] || c=50
  W=$((c - 4)); RULE=""
  while [ "$i" -lt "$W" ]; do RULE="${RULE}─"; i=$((i + 1)); done
}
read_version() { local f="$ROOT/bin/$PLAT/VERSION"; VERSION_TEXT=""; [ ! -f "$f" ] || VERSION_TEXT="$(tr -d '\r\n' <"$f")"; }
read_version

header() {
  local version="${VERSION_TEXT:+Claude Code $VERSION_TEXT}" gap
  version="${version:-Claude Code not downloaded yet}"
  measure
  printf -v gap '%*s' $((W - 18 - ${#version})) ''
  printf '%s\n  %s›_%s %sClaude Portable%s%s%s%s%s\n' "$CLEAR" "$ACCENT$BOLD" "$RESET" "$BOLD" "$RESET" "$gap" "$DIM" "$version" "$RESET"
  printf '  %s%s%s\n\n' "$DIM" "$RULE" "$RESET"
}

draw_menu() {
  local i nw=0 dw name detail
  header
  if [ ${#NAMES[@]} -eq 0 ]; then
    printf '  No projects yet. Press %s+%s to create one on the drive,\n  or %so%s to open a folder on this computer.\n' "$BOLD" "$RESET" "$BOLD" "$RESET"
  else
    printf '  %sPick up where you left off.%s\n\n' "$DIM" "$RESET"
    for i in "${!NAMES[@]}"; do [ "${#NAMES[$i]}" -le "$nw" ] || nw="${#NAMES[$i]}"; done
    [ "$nw" -le 26 ] || nw=26
    dw=$((W - nw - 4))
    for i in "${!NAMES[@]}"; do
      fit name "${NAMES[$i]}" "$nw"; fit detail "${DETAILS[$i]}" "$dw"
      if [ "$i" -eq "$1" ]; then
        printf '  %s›%s %s%s%s  %s\n' "$ACCENT$BOLD" "$RESET" "$BOLD" "$name" "$RESET" "$detail"
      else
        printf '    %s  %s%s%s\n' "$name" "$DIM" "$detail" "$RESET"
      fi
    done
  fi
  [ -z "$2" ] || printf '\n  %s%s%s\n' "$ACCENT" "$2" "$RESET"
  printf '\n  %s%s%s\n' "$DIM" "$RULE" "$RESET"
  [ ${#NAMES[@]} -eq 0 ] || printf '%s\n' "$HINTS_LIST"
  printf '%s\n' "$HINTS_ALWAYS"
}

update_claude() {
  header
  printf '  %sChecking for a newer Claude Code…%s\n\n' "$BOLD" "$RESET"
  printf '%s' "$SHOW_CURSOR"
  bash "$ROOT/system/setup.sh" all || printf '\n  %sThe update didn'\''t finish. Check your internet connection.%s\n' "$ACCENT" "$RESET"
  read_version
  printf '%s\n  %s\n' "$HIDE_CURSOR" "$(hint enter back)"
  [ -n "$SCRIPTED" ] || next_key
}

pick_project() {
  local sel=0 msg="" p
  load_projects
  printf '%s' "$HIDE_CURSOR"
  while :; do
    draw_menu "$sel" "$msg"; msg=""
    next_key
    case "$KEY" in
      up|k) [ "$sel" -le 0 ] || sel=$((sel - 1)) ;;
      down|j) [ "$sel" -ge $((${#NAMES[@]} - 1)) ] || sel=$((sel + 1)) ;;
      enter|n|N)
        [ ${#NAMES[@]} -gt 0 ] || continue
        project="${PATHS[$sel]}"
        if [ "$KEY" = enter ]; then mode='continue'; else mode='new'; fi
        break ;;
      +|=)
        read_text "Name for the new project:"
        case "$TEXT" in
          "") ;;
          */*|.*) msg="Names can't contain / or start with a dot." ;;
          *) if [ -e "$PROJECTS_DIR/$TEXT" ]; then msg="There's already a project called $TEXT."
             else mkdir -p "$PROJECTS_DIR/$TEXT"; project="$PROJECTS_DIR/$TEXT"; mode='new'; break; fi ;;
        esac ;;
      o|O)
        read_text "Folder to open (you can drag it into this window):"
        p="$(printf '%s' "$TEXT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e "s/^[\"']\(.*\)[\"']$/\1/" -e 's/\\\(.\)/\1/g')"
        p="${p/#\~/$HOME}"
        if [ -z "$p" ]; then :
        elif [ -d "$p" ]; then project="$p"; mode='continue'; break
        else msg="Can't find that folder."; fi ;;
      u|U) update_claude ;;
      q|Q|esc) printf '%s%s' "$CLEAR" "$SHOW_CURSOR"; exit 0 ;;
    esac
  done
  printf '%s' "$SHOW_CURSOR"
}

ensure_claude() {
  if [ -n "${CLAUDE_PORTABLE_BIN:-}" ]; then BIN="$CLAUDE_PORTABLE_BIN"; return; fi
  local b="$ROOT/bin/$PLAT/claude"
  if [ ! -f "$b" ]; then
    header
    printf '  %sClaude Code isn'\''t on this drive yet.%s\n\n' "$BOLD" "$RESET"
    printf '  Download it for Windows and Mac now? It'\''s about 700 MB and only needed once.\n'
    printf '  %sIt comes straight from Anthropic, and every file is checked before it'\''s saved.%s\n\n' "$DIM" "$RESET"
    printf '  %s   %s\n' "$(hint enter download)" "$(hint q cancel)"
    next_key
    if [ "$KEY" = enter ] || [ "$KEY" = y ]; then echo; bash "$ROOT/system/setup.sh" all || true; read_version; fi
  fi
  if [ -f "$b" ]; then
    chmod +x "$b" 2>/dev/null || true
    if [ "$os" = darwin ]; then xattr -d com.apple.quarantine "$b" 2>/dev/null || true; fi
    BIN="$b"; return
  fi
  if command -v claude >/dev/null; then BIN="$(command -v claude)"; return; fi
  printf '\n  Claude Code isn'\''t available. Open Claude Portable again to download it.\n'
  exit 1
}

project=""; mode=""; name=""; import=""; pass=()
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; pass+=("$@"); break ;;
    -h|--help|-help) usage; exit 0 ;;
    --new|--continue|--resume|-new|-continue|-resume) mode="${1##*-}" ;;
    --name|-name) name="$2"; shift ;;
    --import|-import) import="$2"; shift ;;
    *) if [ -z "$project" ] && [ -d "$1" ]; then project="$1"; else pass+=("$1"); fi ;;
  esac
  shift
done

mkdir -p "$DATA" "$PORTABLE" "$PROJECTS_DIR"
(cd "$ROOT/system/template" && find . -type f) | while IFS= read -r f; do
  f="${f#./}"; [ -e "$DATA/$f" ] || { mkdir -p "$(dirname "$DATA/$f")"; cp "$ROOT/system/template/$f" "$DATA/$f"; }
done

if [ "$os" = darwin ] && [ ! -e "$ROOT/.git" ]; then
  case "$ROOT" in /Volumes/*) chflags hidden "$ROOT/system" "$ROOT/bin" "$ROOT/data" 2>/dev/null || true ;; esac
fi

if [ -n "$import" ]; then
  full="$(cd "$import" && pwd -P)"; enc="$(encode "$full")"
  src="$HOME/.claude/projects/$enc"
  [ -d "$src" ] || { echo "No Claude Code history for $full on this computer ($src)" >&2; exit 1; }
  key="$(key_of "${name:-$(basename "$full")}")"
  n="$(sync_dir "$src" "$DATA/projects/$enc")"
  save_alias "$key" "$enc" "$full"
  echo "Imported $n file(s) into project '$key'. Its conversations now continue on any computer."
  echo "Next: copy the project folder to $PROJECTS_DIR/$key, or open a folder with the same name on the other computer."
  exit 0
fi

if [ -z "$project" ]; then
  cwd="$(pwd -P)"
  case "$cwd/" in
    "$PROJECTS_DIR"/?*) rest="${cwd#"$PROJECTS_DIR"/}"; project="$PROJECTS_DIR/${rest%%/*}" ;;
    *) pick_project ;;
  esac
fi
ensure_claude
PROJ_PATH="$(cd "$project" && pwd -P)"
KEY="$(key_of "${name:-$(basename "$PROJ_PATH")}")"
AF="$(alias_file "$KEY")"
ENC="$({ [ -f "$AF" ] && awk -F'\t' -v p="$PROJ_PATH" -v o="$OS_NAME" '$2 == p && $3 == o' "$AF"; } | sort -t$'\t' -k5 | tail -1 | cut -f1 || true)"
[ -n "$ENC" ] || ENC="$(encode "$PROJ_PATH")"
SESS_DIR="$DATA/projects/$ENC"

synced=0; others=""
if [ -f "$AF" ]; then
  while IFS=$'\t' read -r a_enc a_path a_os a_host a_last; do
    [ -z "$a_enc" ] || [ "$a_enc" = "$ENC" ] && continue
    synced=$((synced + $(sync_dir "$DATA/projects/$a_enc" "$SESS_DIR")))
    others="$others| $a_os | $a_host | \`$a_path\` | $a_last |"$'\n'
  done <"$AF"
fi
save_alias "$KEY" "$ENC" "$PROJ_PATH"

HANDOFF="$PORTABLE/handoff/$KEY.md"
CTX="$PORTABLE/run/$KEY.md"
mkdir -p "$PORTABLE/handoff" "$PORTABLE/run"
{
  cat <<EOF
# Claude Portable

This Claude Code installation runs from a portable drive shared between several computers (e.g. Windows and macOS). Conversation history and memory travel with the drive, so earlier messages in this conversation may have been written on a different machine, with different paths, shell and toolchains.

## Current machine (authoritative; overrides anything earlier in the conversation)
- OS: $OS_NAME $( [ "$os" = darwin ] && sw_vers -productVersion 2>/dev/null ) ($PLAT), host: $HOST
- Project directory: \`$PROJ_PATH\`
- Toolchains on PATH: $(toolchains)

## This project on other machines
EOF
  if [ -n "$others" ]; then
    printf '| OS | Host | Path | Last used (UTC) |\n|---|---|---|---|\n%s\n' "$others"
    echo "When earlier messages mention those paths, map them to the current project directory. Files may have changed since then: re-read before editing, and don't assume a build or test result from another machine holds here."
  else
    echo "(none yet)"
  fi
  printf '\n## Handoff note\nFile: `%s`\n' "$HANDOFF"
  if [ -f "$HANDOFF" ]; then echo; cat "$HANDOFF"; else echo "(none yet)"; fi
  printf '\nWhen the user runs /handoff or says they are switching computers, rewrite that file with the current state and next steps (what must be done on the other machine, e.g. building Swift on macOS).\n'
} >"$CTX"

has_sessions=""; ls "$SESS_DIR"/*.jsonl >/dev/null 2>&1 && has_sessions=1
[ -n "$mode" ] || mode='continue'
[ "$mode" != continue ] || [ -n "$has_sessions" ] || mode='new'
args=(--system-prompt-snapshot off --append-system-prompt-file "$CTX")
[ "$mode" != continue ] || args+=(--continue)
[ "$mode" != resume ] || args+=(--resume)
args+=(${pass[@]+"${pass[@]}"})

case "$mode" in
  continue) what="continuing your last conversation" ;;
  resume) what="pick a conversation" ;;
  *) what="new conversation" ;;
esac
START="$PORTABLE/run/.start-$$"; touch "$START"
before="$(session_dirs)"
export CLAUDE_CONFIG_DIR="$DATA" DISABLE_AUTOUPDATER=1 CLAUDE_PORTABLE_ROOT="$ROOT"
[ ! -t 1 ] || printf '\e]0;Claude · %s\a' "$KEY"
printf '%s\n  %s›_%s %s%s%s  %s%s%s\n' "$CLEAR" "$ACCENT$BOLD" "$RESET" "$BOLD" "$KEY" "$RESET" "$DIM" "$what" "$RESET"
[ "$synced" -eq 0 ] || printf '  %sBrought in %s file(s) from your other computers.%s\n' "$DIM" "$synced" "$RESET"
echo
cd "$PROJ_PATH"
rc=0; "$BIN" "${args[@]}" || rc=$?

wrote="$(find "$SESS_DIR" -maxdepth 1 -name '*.jsonl' -newer "$START" 2>/dev/null | head -1)"
new="$(session_dirs | grep -vxF -- "$before" || true)"
if [ -z "$wrote" ] && [ -n "$new" ] && [ "$(printf '%s\n' "$new" | wc -l | tr -d ' ')" = 1 ]; then
  sync_dir "$SESS_DIR" "$DATA/projects/$new" >/dev/null
  save_alias "$KEY" "$new" "$PROJ_PATH" "$ENC"
fi
rm -f "$START"
printf '\n  %s›_%s %sSaved to the drive.%s %sClose this window before you eject it.%s\n\n' "$ACCENT$BOLD" "$RESET" "$BOLD" "$RESET" "$DIM" "$RESET"
exit $rc
