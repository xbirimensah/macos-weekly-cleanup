#!/bin/bash
# Builds the runner pinned to one exact weekly-cleanup.sh.
#
#   runner/build.sh source SCRIPT                 print the pinned Swift source
#   runner/build.sh binary SCRIPT OUT IDENTIFIER  compile + ad-hoc sign to OUT
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
mode="${1:?usage: build.sh source|binary SCRIPT [OUT IDENTIFIER]}"
script="${2:?script path required}"
[ -f "$script" ] || { echo "build.sh: no such script: $script" >&2; exit 1; }

sha=$(shasum -a 256 "$script" | cut -d' ' -f1)
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "build.sh: could not hash $script" >&2; exit 1; }
pinned() { sed "s/@SCRIPT_SHA256@/$sha/" "$HERE/cleanup-runner.swift"; }

case "$mode" in
  source) pinned ;;
  binary)
    out="${3:?output path required}"; ident="${4:?signing identifier required}"
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    pinned > "$tmp/runner.swift"
    swiftc -O "$tmp/runner.swift" -o "$tmp/runner"
    codesign -s - -i "$ident" -f "$tmp/runner" >/dev/null 2>&1
    mv -f "$tmp/runner" "$out"
    ;;
  *) echo "build.sh: unknown mode '$mode'" >&2; exit 1 ;;
esac
