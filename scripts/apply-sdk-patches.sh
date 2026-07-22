#!/usr/bin/env bash
# Re-apply wellmusic SDK patches after a Native SDK upgrade.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
sdk="$(cd "$root/.native/build" && node -e "
const fs=require('fs');
const zon=fs.readFileSync('build.zig.zon','utf8');
const m=zon.match(/native_sdk = \\.\\{ \\.path = \"([^\"]+)\" \\}/);
if(!m){console.error('native_sdk path not found'); process.exit(1);}
console.log(require('path').resolve('.', m[1]));
")"
echo "SDK: $sdk"
for patch in "$root"/patches/*.patch; do
  [ -f "$patch" ] || continue
  echo "Applying $(basename "$patch")"
  if patch -p1 -d "$sdk" --forward --dry-run <"$patch" >/dev/null 2>&1; then
    patch -p1 -d "$sdk" --forward <"$patch"
  elif patch -p1 -d "$sdk" --reverse --dry-run <"$patch" >/dev/null 2>&1; then
    echo "  already applied"
  else
    echo "  failed to apply" >&2
    exit 1
  fi
done
