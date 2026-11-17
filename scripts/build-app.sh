#!/usr/bin/env bash
# Compila e monta dist/KiroChat.app (o binário kiro-chat-mcp vai dentro do bundle).
# Uso: scripts/build-app.sh [--install]   (--install copia para /Applications)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/KiroChat.app"

swift build -c release --product KiroChat
swift build -c release --product kiro-chat-mcp
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/KiroChat" "$APP/Contents/MacOS/KiroChat"
cp "$BIN/kiro-chat-mcp" "$APP/Contents/MacOS/kiro-chat-mcp"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Kiro Chat</string>
    <key>CFBundleDisplayName</key><string>Kiro Chat</string>
    <key>CFBundleIdentifier</key><string>dev.kirochat.app</string>
    <key>CFBundleExecutable</key><string>KiroChat</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/MacOS/kiro-chat-mcp"
codesign --force --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf /Applications/KiroChat.app
    cp -R "$APP" /Applications/KiroChat.app
    APP=/Applications/KiroChat.app
fi

echo
echo "✅ App:        $APP"
echo "✅ MCP server: $APP/Contents/MacOS/kiro-chat-mcp"
