#!/usr/bin/env bash
# Compila e monta dist/KiroChat.app (o binário kiro-chat-mcp vai dentro do bundle).
# Uso: scripts/build-app.sh [--install] [--universal] [--zip]
#   --install    copia para /Applications
#   --universal  binários para Apple Silicon e Intel (usado nas releases)
#   --zip        gera dist/KiroChat.zip e dist/KiroChat.zip.sha256
# A versão vem do arquivo VERSION.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/dist/KiroChat.app"

INSTALL=0; UNIVERSAL=0; ZIP=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --universal) UNIVERSAL=1 ;;
        --zip) ZIP=1 ;;
        *) echo "Opção desconhecida: $arg" >&2; exit 2 ;;
    esac
done

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

ARCH_FLAGS=()
if [[ $UNIVERSAL == 1 ]]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product KiroChat
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product kiro-chat-mcp
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/KiroChat" "$APP/Contents/MacOS/KiroChat"
cp "$BIN/kiro-chat-mcp" "$APP/Contents/MacOS/kiro-chat-mcp"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Kiro Chat</string>
    <key>CFBundleDisplayName</key><string>Kiro Chat</string>
    <key>CFBundleIdentifier</key><string>dev.kirochat.app</string>
    <key>CFBundleExecutable</key><string>KiroChat</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/MacOS/kiro-chat-mcp"
codesign --force --sign - "$APP"

if [[ $ZIP == 1 ]]; then
    rm -f "$ROOT/dist/KiroChat.zip" "$ROOT/dist/KiroChat.zip.sha256"
    (cd "$ROOT/dist" && ditto -c -k --keepParent KiroChat.app KiroChat.zip \
        && shasum -a 256 KiroChat.zip > KiroChat.zip.sha256)
fi

if [[ $INSTALL == 1 ]]; then
    rm -rf /Applications/KiroChat.app
    cp -R "$APP" /Applications/KiroChat.app
    APP=/Applications/KiroChat.app
fi

echo
echo "✅ App:        $APP (versão $VERSION)"
echo "✅ MCP server: $APP/Contents/MacOS/kiro-chat-mcp"
if [[ $ZIP == 1 ]]; then echo "✅ Zip:        $ROOT/dist/KiroChat.zip"; fi
