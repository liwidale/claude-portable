#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BASE="https://downloads.claude.ai/claude-code-releases"
version=stable
platforms=()
while [ $# -gt 0 ]; do
  case "$1" in
    --version|-version) version="$2"; shift ;;
    all) platforms+=(win32-x64 darwin-arm64 darwin-x64) ;;
    *) platforms+=("$1") ;;
  esac
  shift
done
if [ ${#platforms[@]} -eq 0 ]; then
  case "$(uname -s)" in Darwin) os=darwin ;; *) os=linux ;; esac
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=x64 ;; esac
  [ "$os" = darwin ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ] && arch=arm64
  platforms=("$os-$arch")
fi

sha256() { if command -v shasum >/dev/null; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || version="$(curl -fsSL "$BASE/$version")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || { echo "Could not get a version from downloads.claude.ai" >&2; exit 1; }
manifest="$(curl -fsSL "$BASE/$version/manifest.json" | tr -d '\n\r')"
echo "Claude Code $version"

for p in "${platforms[@]}"; do
  if [[ ! "$manifest" =~ \"$p\"[[:space:]]*:[[:space:]]*\{([^{}]*)\} ]]; then echo "Platform $p is not in the manifest" >&2; continue; fi
  obj="${BASH_REMATCH[1]}"
  [[ "$obj" =~ \"checksum\"[[:space:]]*:[[:space:]]*\"([a-f0-9]{64})\" ]] && checksum="${BASH_REMATCH[1]}"
  [[ "$obj" =~ \"binary\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]] && binary="${BASH_REMATCH[1]}"
  [[ "$obj" =~ \"size\"[[:space:]]*:[[:space:]]*([0-9]+) ]] && size="${BASH_REMATCH[1]}"
  dir="$ROOT/bin/$p"; dest="$dir/$binary"
  if [ -f "$dest" ] && [ "$(tr -d '\r\n' <"$dir/VERSION" 2>/dev/null)" = "$version" ]; then echo "  $p is already $version"; continue; fi
  mkdir -p "$dir"
  echo "  $p downloading $((size / 1048576)) MB..."
  curl -fL --progress-bar -o "$dest.download" "$BASE/$version/$p/$binary"
  if [ "$(sha256 "$dest.download")" != "$checksum" ]; then
    rm -f "$dest.download"; echo "Checksum mismatch for $p, the download was deleted" >&2; exit 1
  fi
  mv -f "$dest.download" "$dest"
  chmod +x "$dest" 2>/dev/null || true
  echo "$version" >"$dir/VERSION"
  echo "  $p OK"
done
