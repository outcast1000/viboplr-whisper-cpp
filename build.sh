#!/usr/bin/env bash
# Builds a self-contained whisper-cli from the source pinned in sources.txt.
#
#   ./build.sh version   print the version this recipe produces (no build)
#   ./build.sh build     fetch, build and package into $WHISPER_WORK/out
#
# Platform comes from the host: macOS arm64 (Metal, embedded shader library,
# Accelerate) or Windows x64 (MSVC, CPU, static CRT). Run from Git Bash on
# Windows. Everything links statically; the workflow checks that the binary
# depends on nothing but the OS.
#
# The version is <whisper.cpp base>-<build number>-<recipe rev>, e.g.
# 1.9.6-5907-1. It is compiled into the binary (whisper-cli --version prints
# "whisper.cpp version: 1.9.6-5907-1") and the release is tagged v<version>,
# because Vibo's tool update check compares the two.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WHISPER_WORK:-$HERE/work}"
SRC="$WORK/src"
OUT="$WORK/out"

# Read KEY=value lines without executing the file (macOS bash 3.2 can't
# `source` a process substitution).
WHISPER_TAG="" WHISPER_COMMIT="" RECIPE_REV=""
while IFS='=' read -r key value; do
  case "$key" in
    WHISPER_TAG) WHISPER_TAG="$value" ;;
    WHISPER_COMMIT) WHISPER_COMMIT="$value" ;;
    RECIPE_REV) RECIPE_REV="$value" ;;
  esac
done < <(grep -E '^[A-Z_]+=' "$HERE/sources.txt" | tr -d '\r')

[[ "$WHISPER_TAG" =~ ^b[0-9]+$ ]] || { echo "WHISPER_TAG must look like b1234" >&2; exit 1; }
[[ "$WHISPER_COMMIT" =~ ^[0-9a-f]{40}$ ]] || { echo "WHISPER_COMMIT must be a full sha" >&2; exit 1; }
[[ "$RECIPE_REV" =~ ^[0-9]+$ ]] || { echo "RECIPE_REV must be a number" >&2; exit 1; }
BUILD_NUMBER="${WHISPER_TAG#b}"

case "$(uname -s)" in
  Darwin) PLATFORM=macos-arm64; EXE=whisper-cli ;;
  MINGW*|MSYS*|CYGWIN*) PLATFORM=windows-x64; EXE=whisper-cli.exe ;;
  *) echo "Unsupported host $(uname -s)" >&2; exit 1 ;;
esac
ASSET="whisper-cli-$PLATFORM"
[[ "$PLATFORM" == windows-x64 ]] && ASSET="$ASSET.exe"

fetch() {
  if [[ ! -d "$SRC/.git" ]]; then
    git clone --quiet --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp.git "$SRC"
  fi
  local got
  got="$(git -C "$SRC" rev-parse HEAD)"
  if [[ "$got" != "$WHISPER_COMMIT" ]]; then
    echo "$WHISPER_TAG resolves to $got, sources.txt pins $WHISPER_COMMIT — refusing to build" >&2
    exit 1
  fi
}

base_version() {
  local major minor patch
  major="$(sed -nE 's/^set\(WHISPER_VERSION_MAJOR ([0-9]+)\)/\1/p' "$SRC/CMakeLists.txt")"
  minor="$(sed -nE 's/^set\(WHISPER_VERSION_MINOR ([0-9]+)\)/\1/p' "$SRC/CMakeLists.txt")"
  patch="$(sed -nE 's/^set\(WHISPER_VERSION_PATCH ([0-9]+)\)/\1/p' "$SRC/CMakeLists.txt")"
  [[ -n "$major" && -n "$minor" && -n "$patch" ]] || { echo "Couldn't read whisper.cpp's version" >&2; exit 1; }
  echo "$major.$minor.$patch"
}

version() { echo "$(base_version)-$BUILD_NUMBER-$RECIPE_REV"; }

# Make the release build report our version instead of the bare base.
stamp_version() {
  local v="$1" line='    set(WHISPER_VERSION "${WHISPER_VERSION_BASE}")'
  if [[ "$(grep -cxF "$line" "$SRC/CMakeLists.txt")" != 1 ]]; then
    echo "CMakeLists.txt no longer has the release-version line build.sh rewrites" >&2
    exit 1
  fi
  local tmp="$SRC/CMakeLists.txt.tmp"
  awk -v line="$line" -v repl="    set(WHISPER_VERSION \"$v\")" '$0 == line { print repl; next } { print }' \
    "$SRC/CMakeLists.txt" > "$tmp"
  mv "$tmp" "$SRC/CMakeLists.txt"
}

COMMON_FLAGS=(
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_SHARED_LIBS=OFF
  -DWHISPER_BUILD_IS_DEV=OFF
  -DWHISPER_BUILD_EXAMPLES=ON
  -DWHISPER_BUILD_TESTS=OFF
  -DWHISPER_BUILD_SERVER=OFF
  -DWHISPER_SDL2=OFF
  -DWHISPER_CURL=OFF
  -DWHISPER_COREML=OFF
  -DWHISPER_OPENVINO=OFF
  -DGGML_NATIVE=OFF
)

build() {
  fetch
  local v
  v="$(version)"
  stamp_version "$v"
  rm -rf "$WORK/build" "$OUT"
  mkdir -p "$OUT"

  if [[ "$PLATFORM" == macos-arm64 ]]; then
    # M1 is the floor: dotprod + fp16, nothing newer, so a build on newer
    # runner hardware can't emit instructions an M1 lacks.
    cmake -S "$SRC" -B "$WORK/build" "${COMMON_FLAGS[@]}" \
      -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 \
      -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16 \
      -DGGML_METAL=ON \
      -DGGML_METAL_EMBED_LIBRARY=ON \
      -DGGML_BLAS=ON \
      -DGGML_BLAS_VENDOR=Apple
    cmake --build "$WORK/build" --config Release --target whisper-cli -j "$(sysctl -n hw.ncpu)"
    cp "$WORK/build/bin/whisper-cli" "$OUT/$ASSET"
  else
    # cmake_minimum_required(3.5) leaves CMP0091 OLD, which ignores
    # CMAKE_MSVC_RUNTIME_LIBRARY — set it NEW or the CRT stays a DLL.
    # AVX2 + FMA + F16C: every x64 CPU since Haswell (2013).
    cmake -S "$SRC" -B "$WORK/build" -G "Visual Studio 17 2022" -A x64 "${COMMON_FLAGS[@]}" \
      -DCMAKE_POLICY_DEFAULT_CMP0091=NEW \
      -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded \
      -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON
    cmake --build "$WORK/build" --config Release --target whisper-cli -j "${NUMBER_OF_PROCESSORS:-4}"
    cp "$WORK/build/bin/Release/whisper-cli.exe" "$OUT/$ASSET"
  fi

  cat > "$OUT/build-info-$PLATFORM.json" <<JSON
{
  "version": "$v",
  "platform": "$PLATFORM",
  "asset": "$ASSET",
  "whisperTag": "$WHISPER_TAG",
  "whisperCommit": "$WHISPER_COMMIT",
  "recipeRev": $RECIPE_REV
}
JSON
  echo "Built $ASSET ($v)"
}

case "${1:-}" in
  version) fetch; version ;;
  build) build ;;
  *) echo "usage: $0 version|build" >&2; exit 2 ;;
esac
