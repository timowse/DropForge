# DropForge — third-party notices

DropForge's own code was written for this project. It runs the following separately licensed,
redistributable open-source programs as **separate helper processes** (they are not linked into
DropForge). Full licence texts shipped with each package are in `Contents/Resources/Licenses/`.

| component | version | licence | source |
| --- | --- | --- | --- |
| FFmpeg (`ffmpeg`, `ffprobe`, libav*) | 9.0.2 | GPL-3.0-or-later (built with `--enable-gpl --enable-version3`) | https://ffmpeg.org/releases/ |
| x264 | r3222 | GPL-2.0-or-later | https://code.videolan.org/videolan/x264 |
| x265 | 4.3 | GPL-2.0-or-later | https://bitbucket.org/multicoreware/x265_git |
| libvpx | 1.17.0 | BSD-3-Clause + patent grant | https://chromium.googlesource.com/webm/libvpx |
| Opus | 1.6.1 | BSD-3-Clause | https://opus-codec.org |
| LAME | see Licenses/ | LGPL-2.0-or-later | https://lame.sourceforge.io |
| mpg123 | 1.33.7 | LGPL-2.1 | https://www.mpg123.de |
| SVT-AV1 | 4.2.0 | BSD-3-Clause-Clear + AOM patent licence | https://gitlab.com/AOMediaCodec/SVT-AV1 |
| dav1d | 1.5.4 | BSD-2-Clause | https://code.videolan.org/videolan/dav1d |
| libvmaf | 3.2.1 | BSD-2-Clause-Patent | https://github.com/Netflix/vmaf |
| OpenSSL (libcrypto, libssl; linked by FFmpeg, unused by DropForge) | 4.0.3 | Apache-2.0 | https://www.openssl.org |
| xz / liblzma | 5.8.4 | 0BSD | https://tukaani.org/xz/ |
| Zstandard | 1.5.7 | BSD-3-Clause | https://github.com/facebook/zstd |
| libwebp, libsharpyuv (`cwebp`) | 1.6.0 | BSD-3-Clause | https://chromium.googlesource.com/webm/libwebp |
| libpng | 1.6.58 | libpng-2.0 | http://www.libpng.org |
| libjpeg-turbo | 3.2.0 | IJG + BSD-3-Clause + zlib | https://libjpeg-turbo.org |
| LibTIFF | 4.7.2 | libtiff (BSD-style) | https://libtiff.gitlab.io/libtiff/ |

The binaries are the Homebrew bottles of these versions, copied unmodified except for rewritten
dynamic-library load paths and an ad-hoc code signature. The corresponding source code is
available from the URLs above and from https://github.com/Homebrew/homebrew-core (formula
sources). On request, the exact source archives used for this build can be provided.

Not bundled, used only when present on the Mac: macOS system tools (`/usr/bin/bsdtar` —
libarchive, BSD-2-Clause; `/usr/bin/gzip`; `/usr/bin/ditto`; `/usr/bin/osascript`),
LibreOffice (MPL-2.0, installed separately by the user), and Apple's Keynote, Pages and Numbers.

DropForge does not contain code, assets, icons or text from Tangerine or any other commercial app.
