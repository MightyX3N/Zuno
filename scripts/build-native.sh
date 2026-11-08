#!/usr/bin/env bash
# Builds Zuno's native crypto library (Monocypher + optional Ed25519) into build/native/.
#   scripts/build-native.sh            -> build/native/linux-x64/libzunocrypto.so
#   scripts/build-native.sh win64      -> build/native/win64/zunocrypto.dll   (needs mingw-w64)
#   scripts/build-native.sh all
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="native/monocypher/monocypher.c native/monocypher/monocypher-ed25519.c"
CFLAGS="-O3 -std=c99 -Wall -Wextra -fvisibility=default"

build_linux() {
  mkdir -p build/native/linux-x64
  ${CC:-gcc} $CFLAGS -fPIC -shared -o build/native/linux-x64/libzunocrypto.so $SRC
  echo "built build/native/linux-x64/libzunocrypto.so"
}

build_win64() {
  mkdir -p build/native/win64
  # Monocypher has no export annotations, so export every symbol from the DLL.
  x86_64-w64-mingw32-gcc $CFLAGS -shared -static-libgcc -Wl,--export-all-symbols \
    -o build/native/win64/zunocrypto.dll $SRC
  echo "built build/native/win64/zunocrypto.dll"
}

case "${1:-linux}" in
  linux) build_linux ;;
  win64) build_win64 ;;
  all) build_linux; build_win64 ;;
  *) echo "usage: $0 [linux|win64|all]" >&2; exit 1 ;;
esac
