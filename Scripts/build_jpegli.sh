#!/usr/bin/env bash
# Builds the jpegli encoder (part of libjxl) as static libraries for Apple Silicon
# and installs headers + libs into Vendor/jpegli. Package.swift picks them up
# automatically; without them the app falls back to the system JPEG encoder.
#
# Requirements: git, cmake (brew install cmake), Xcode command line tools.
set -euo pipefail

LIBJXL_TAG="${LIBJXL_TAG:-v0.11.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Vendor/jpegli"
WORK="${JPEGLI_WORK_DIR:-$ROOT/.build/jpegli-src}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"

if [[ -f "$DEST/lib/libjpegli-static.a" && "${FORCE:-0}" != "1" ]]; then
  echo "jpegli already built in $DEST (set FORCE=1 to rebuild)"
  exit 0
fi

command -v cmake >/dev/null || { echo "cmake not found: brew install cmake" >&2; exit 1; }

mkdir -p "$WORK"
if [[ ! -d "$WORK/libjxl/.git" ]]; then
  git clone --depth 1 --branch "$LIBJXL_TAG" https://github.com/libjxl/libjxl.git "$WORK/libjxl"
fi
cd "$WORK/libjxl"
git submodule update --init --depth 1 \
  third_party/highway third_party/libjpeg-turbo third_party/lcms third_party/brotli

CMAKE_EXTRA=()
if [[ "$(uname)" == "Darwin" ]]; then
  CMAKE_EXTRA+=(-DCMAKE_OSX_ARCHITECTURES="${ARCHS:-arm64}" -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0)
fi

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_TESTING=OFF -DBUILD_SHARED_LIBS=OFF \
  -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_JPEGLI=ON -DJPEGXL_ENABLE_JPEGLI_LIBJPEG=OFF \
  -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF \
  -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF \
  -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SKCMS=OFF -DJPEGXL_ENABLE_TRANSCODE_JPEG=OFF \
  -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_FORCE_SYSTEM_BROTLI=OFF -DJPEGXL_FORCE_SYSTEM_LCMS2=OFF \
  -DJPEGXL_FORCE_SYSTEM_HWY=OFF \
  "${CMAKE_EXTRA[@]}"
cmake --build build --target jpegli-static -j "$JOBS"

rm -rf "$DEST"
mkdir -p "$DEST/lib" "$DEST/include/lib/jpegli" "$DEST/include/lib/jxl/base"
cp build/lib/libjpegli-static.a "$DEST/lib/"
cp build/third_party/highway/libhwy.a "$DEST/lib/"
cp lib/jpegli/encode.h lib/jpegli/common.h lib/jpegli/types.h "$DEST/include/lib/jpegli/"
cp lib/jxl/base/include_jpeglib.h "$DEST/include/lib/jxl/base/"
cp build/lib/include/jpegli/jpeglib.h build/lib/include/jpegli/jconfig.h \
   build/lib/include/jpegli/jmorecfg.h "$DEST/include/"
cp LICENSE "$DEST/LICENSE-libjxl"
echo "jpegli installed into $DEST"
