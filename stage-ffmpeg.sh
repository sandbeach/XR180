#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

app="${1:?Pass the path to an app bundle}"
release=9.0.1-1
arch=$(uname -m)
case "$arch" in
  arm64) checksum=d0ea5ea43a5adfa5d01d4137c9e5a61728b800a812f12917a26fd7af0c14c03a ;;
  x86_64) checksum=d63ad731cbf1eb71c2055130fedfbd7e49edd60a9815ab763e72ba802c1ac666 ;;
  *) echo "Unsupported architecture: $arch" >&2; exit 2 ;;
esac

name="ffmpeg-$release-lgpl-macos-$arch"
cache="$PWD/build/ffmpeg"
mkdir -p "$cache"
archive="$cache/$name.tar.xz"
verified() { printf '%s  %s\n' "$checksum" "$1" | shasum -a 256 -c --status; }

scratch=$(mktemp -d "$cache/stage.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
if [[ ! -f "$archive" ]] || ! verified "$archive"; then
  curl --fail --location --silent --show-error --retry 2 \
    -o "$scratch/$name.tar.xz" \
    "https://github.com/dfloresc/ffmpeg-macos-builds/releases/download/v$release/$name.tar.xz"
  verified "$scratch/$name.tar.xz" || { echo "FFmpeg checksum mismatch" >&2; exit 1; }
  mv "$scratch/$name.tar.xz" "$archive"
fi
tar -xf "$archive" -C "$scratch" "$name/bin" "$name/lib" "$name/BUILDINFO.txt" "$name/LICENSES"

runtime="$scratch/$name"
helpers="$app/Contents/Helpers"
libraries="$app/Contents/Frameworks"
notices="$app/Contents/Resources/FFmpeg"
mkdir -p "$helpers" "$libraries" "$notices"
cp -R "$runtime/lib/"*.dylib "$libraries/"
cp -R "$runtime/BUILDINFO.txt" "$runtime/LICENSES" FFmpeg-NOTICE.md "$notices/"

for library in "$libraries/"*.dylib; do
  [[ -L "$library" ]] || codesign --force --sign - "$library"
done
for name in ffmpeg ffprobe; do
  cp "$runtime/bin/$name" "$helpers/$name"
  install_name_tool -rpath '@executable_path/../lib' '@executable_path/../Frameworks' "$helpers/$name"
  codesign --force --sign - "$helpers/$name"
done
