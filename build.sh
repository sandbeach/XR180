#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="${1:-$PWD/build/XR180.app}"
case "$app" in
  *.app) ;;
  *) echo 'Output must end in .app' >&2; exit 2 ;;
esac

mkdir -p "$PWD/build/modules" "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
cp Sources/Projection.metal "$app/Contents/Resources/"
compiler=$(xcrun --find swiftc)
sdk=$(xcrun --sdk macosx --show-sdk-path)
arch=$(uname -m)
"$compiler" -O -sdk "$sdk" -target "$arch-apple-macosx13.0" \
  -module-cache-path "$PWD/build/modules" Sources/*.swift -o "$app/Contents/MacOS/XR180"
codesign --force --sign - "$app"
echo "$app"
