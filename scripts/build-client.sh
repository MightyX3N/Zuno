#!/usr/bin/env bash
# Assembles the LÖVE client into build/client/ (run it with: love build/client)
# and packs build/zuno.love.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/client
rm -rf "$OUT"; mkdir -p "$OUT"
cp client/main.lua client/conf.lua "$OUT/"
cp -r client/zuno_native client/assets "$OUT/"
mkdir -p "$OUT/protocol" "$OUT/server" "$OUT/ui" "$OUT/layouts"
cp -r protocol/zuno "$OUT/protocol/"
cp -r server/zuno_server "$OUT/server/"
cp -r ui/zuno_ui "$OUT/ui/"
cp -r layouts/tabs "$OUT/layouts/"
[ -f build/native/linux-x64/libzunocrypto.so ] || scripts/build-native.sh linux
cp build/native/linux-x64/libzunocrypto.so "$OUT/"
(cd "$OUT" && rm -f ../zuno.love && zip -qr ../zuno.love . -x 'libzunocrypto.so')
echo "built $OUT and build/zuno.love"
