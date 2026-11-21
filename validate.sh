#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
validation="$PWD/build/Validate.app"
mkdir -p "$validation/Contents/MacOS" "$validation/Contents/Resources" "$PWD/build/modules"
cp Info.plist "$validation/Contents/Info.plist"
cp Sources/Projection.metal "$validation/Contents/Resources/"
xcrun swiftc -O -module-cache-path "$PWD/build/modules" \
  Sources/Tracking.swift Sources/Renderer.swift Sources/Playback.swift Sources/RemoteSource.swift Sources/SMBKeychain.swift Validation/main.swift \
  -o "$validation/Contents/MacOS/XR180"
fixture=$(mktemp -d "$PWD/build/fixture.XXXXXX")
trap 'rmdir "$fixture" 2>/dev/null || true' EXIT
"$validation/Contents/MacOS/XR180" "$fixture/stereo.mp4"
