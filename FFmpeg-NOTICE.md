# FFmpeg

XR180 includes the LGPL build of FFmpeg 9.0.1 packaged by the
[FFmpeg macOS builds project](https://github.com/dfloresc/ffmpeg-macos-builds/releases/tag/v9.0.1-1).
XR180 invokes `ffmpeg` and `ffprobe` as separate executables. Their FFmpeg
libraries are distributed as dylibs. XR180 changes the helpers' library search
path for the macOS bundle layout and signs the nested binaries.

The binary distribution includes the applicable licenses and the original
`BUILDINFO.txt` with source URLs, checksums and build configuration. The
[packager's release](https://github.com/dfloresc/ffmpeg-macos-builds/releases/tag/v9.0.1-1)
provides the corresponding source archives, including the sources of the codec
libraries. The [packager's build scripts](https://github.com/dfloresc/ffmpeg-macos-builds/tree/e95a80ee4eeaf8bdb4f208ccbc1952eb79e0b08a)
and [upstream FFmpeg source](https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz)
are also available.
