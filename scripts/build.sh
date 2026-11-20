#!/bin/bash
# Compile PillChat et assemble PillChat.app — sans Xcode (outils en ligne de commande suffisent).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="build/PillChat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/PillChat" "$APP/Contents/MacOS/PillChat"
if compgen -G "Resources/*" >/dev/null; then cp Resources/* "$APP/Contents/Resources/"; fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PillChat</string>
    <key>CFBundleDisplayName</key><string>PillChat</string>
    <key>CFBundleIdentifier</key><string>app.pillchat.PillChat</string>
    <key>CFBundleExecutable</key><string>PillChat</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>PillChat utilise Messages pour envoyer tes réponses.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>PillChat enregistre tes messages vocaux.</string>
    <key>NSContactsUsageDescription</key>
    <string>PillChat affiche le nom et la photo de tes contacts.</string>
</dict>
</plist>
PLIST

# Certificat local « PillChat Dev » s'il existe : la signature reste la même d'une compilation à l'autre,
# donc macOS garde les autorisations (accès au disque, micro…). Sinon, signature ad hoc.
if security find-identity -p codesigning | grep -q "PillChat Dev"; then
    codesign --force --sign "PillChat Dev" --identifier app.pillchat.PillChat "$APP" >/dev/null
else
    codesign --force --sign - "$APP" >/dev/null
fi
echo "✅ $APP"
