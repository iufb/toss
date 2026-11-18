#!/bin/bash
# Собирает Toss.app рядом со скриптом.
# Нужны Command Line Tools: xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP="Toss.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # иконку рисует make_icon.swift

swiftc -O main.swift \
  -o "$APP/Contents/MacOS/Toss" \
  -framework Cocoa -framework IOBluetooth -framework ServiceManagement

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>             <string>Toss</string>
  <key>CFBundleIdentifier</key>       <string>local.toss</string>
  <key>CFBundleExecutable</key>       <string>Toss</string>
  <key>CFBundleIconFile</key>         <string>AppIcon</string>
  <key>CFBundlePackageType</key>      <string>APPL</string>
  <key>CFBundleVersion</key>          <string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key>   <string>13.0</string>
  <key>LSUIElement</key>              <true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Нужно, чтобы подключать и отключать выбранные наушники.</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Готово: $(pwd)/$APP"
