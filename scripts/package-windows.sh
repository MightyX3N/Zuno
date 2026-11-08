#!/usr/bin/env bash
# Builds build/dist/Zuno-<version>-win64.zip:
#   Zuno.exe          desktop client (LÖVE 11.5, fused)
#   Zuno Server.exe   standalone server in a console window (same LÖVE runtime)
#   zunocrypto.dll, sqlite3.dll and LÖVE's own DLLs
# Needs: mingw-w64, zip, curl, npm (only to fetch the SQLite amalgamation once).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(luajit -e 'package.path="protocol/?.lua;"..package.path; io.write(require("zuno.version").APP)')
CACHE=build/cache
OUT=build/win64
DIST=build/dist
mkdir -p "$CACHE" "$DIST"

# 1. LÖVE runtime for Windows
LOVE_ZIP="$CACHE/love-11.5-win64.zip"
if [ ! -f "$LOVE_ZIP" ]; then
  curl -fsSL -o "$LOVE_ZIP" https://github.com/love2d/love/releases/download/11.5/love-11.5-win64.zip
fi
rm -rf "$CACHE/love-win64"; mkdir -p "$CACHE/love-win64"
unzip -q "$LOVE_ZIP" -d "$CACHE/love-win64"
LOVE_DIR=$(dirname "$(find "$CACHE/love-win64" -name love.exe | head -1)")

# 2. Native libraries
scripts/build-native.sh win64
SQLITE_C="$CACHE/sqlite/package/deps/sqlite3/sqlite3.c"
if [ ! -f "$SQLITE_C" ]; then
  (cd "$CACHE" && npm pack better-sqlite3@11.3.0 --silent >/dev/null && mkdir -p sqlite && tar xzf better-sqlite3-11.3.0.tgz -C sqlite)
fi
if [ ! -f "$CACHE/sqlite3.dll" ]; then
  x86_64-w64-mingw32-gcc -O2 -shared -static-libgcc '-DSQLITE_API=__declspec(dllexport)' -DSQLITE_THREADSAFE=1 \
    -o "$CACHE/sqlite3.dll" "$SQLITE_C"
fi

# 3. Game files
scripts/build-client.sh >/dev/null
rm -rf build/server-love; mkdir -p build/server-love/protocol build/server-love/server
cp server/love/main.lua server/love/conf.lua build/server-love/
cp -r protocol/zuno build/server-love/protocol/
cp -r server/zuno_server build/server-love/server/
(cd build/server-love && rm -f ../zuno-server.love && zip -qr ../zuno-server.love .)

# 4. Assemble
rm -rf "$OUT"; mkdir -p "$OUT/licenses"
# Zuno's icon and name (Windows shows the name in notifications) go into the exe first;
# the game archive must stay at the very end of the file.
python3 scripts/set-exe-resources.py "$LOVE_DIR/love.exe" "$CACHE/Zuno.exe" client/assets/icon/zuno.ico "Zuno" "Zuno" "$VERSION"
python3 scripts/set-exe-resources.py "$LOVE_DIR/love.exe" "$CACHE/Zuno Server.exe" client/assets/icon/zuno.ico "Zuno Server" "Zuno" "$VERSION"
cat "$CACHE/Zuno.exe" build/zuno.love > "$OUT/Zuno.exe"
cat "$CACHE/Zuno Server.exe" build/zuno-server.love > "$OUT/Zuno Server.exe"
cp "$LOVE_DIR"/*.dll "$OUT/"
cp build/native/win64/zunocrypto.dll "$CACHE/sqlite3.dll" "$OUT/"
cp "$LOVE_DIR/license.txt" "$OUT/licenses/LOVE.txt"
cp native/monocypher/LICENCE.md "$OUT/licenses/Monocypher.txt"
cp client/assets/fonts/Inter-OFL.txt "$OUT/licenses/Inter-OFL.txt"
cp client/assets/fonts/SpaceGrotesk-OFL.txt "$OUT/licenses/SpaceGrotesk-OFL.txt"
cp client/assets/fonts/JetBrainsMono-OFL.txt "$OUT/licenses/JetBrainsMono-OFL.txt"
cp client/assets/emoji/LICENSE.txt "$OUT/licenses/Twemoji-and-emoji-data.txt"
cat > "$OUT/README.txt" <<EOF
Zuno $VERSION (test build) for Windows 64-bit
https://zuno.dovecross.site

Zuno.exe
  The chat app. Join a server with its address, or press "Start server" to host one
  on this PC while Zuno is open.

Zuno Server.exe
  A server on its own, in a console window (no chat window). Data is stored in the
  "server-data" folder next to it. The first time it starts it prints a claim code:
  connect with Zuno and send  /claim CODE  to become the owner.
  Options: --port 41234 --name "My server" --data C:\\path\\to\\folder

Letting friends in
  Create a TCP tunnel in playit.gg pointing at the server's port (41234 by default)
  and send your friends the tunnel address.

Running two clients on one PC (for testing)
  Start the second one from a command prompt with:  set ZUNO_PROFILE=test && Zuno.exe

Your account
  Your account is a key stored on this PC (no password). In Settings you can back it
  up to a .zunokey file with a recovery key, link another device, or replace the key
  if a device is lost. Streamer mode hides addresses and keys while OBS is running.

Chatting
  **bold**, *italic*, ~~strike~~, \`code\`, \`\`\`code blocks\`\`\` and > quotes work in messages.
  Type @ to mention someone and : to find an emoji. Hover a message to react or reply.
  Settings > Notifications decides what makes a notification while Zuno is open.

This is an early test build: text chat only. Voice, files and more come later.
EOF
sed -i 's/$/\r/' "$OUT/README.txt"
rm -f "$DIST/Zuno-$VERSION-win64.zip"
(cd "$OUT" && zip -qr "../../$DIST/Zuno-$VERSION-win64.zip" .)
echo "built $DIST/Zuno-$VERSION-win64.zip"
