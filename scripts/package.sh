#!/bin/sh
# Build GpuFanApp (release) and assemble a menu-bar-only .app bundle, ad-hoc
# signed so SMAppService "Launch at login" works. Output: dist/GpuFan.app
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="GpuFan"
DISPLAY_NAME="GPU Fan"
BUNDLE_ID="com.gpufan.app"
VERSION="1.0"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> building release binary"
swift build -c release --product GpuFanApp
BIN="$(swift build -c release --product GpuFanApp --show-bin-path)/GpuFanApp"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Optional app icon: drop an AppIcon.icns in Resources/ to use it.
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" \
    "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi

echo "==> ad-hoc code signing"
codesign --force --deep --sign - "$APP"

echo ""
echo "Built: $APP"
echo "Install with:"
echo "  cp -R \"$APP\" /Applications/ && open /Applications/$APP_NAME.app"
echo "(Run it from /Applications so the login item path stays stable.)"
