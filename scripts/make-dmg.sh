#!/bin/bash
# Builds a release TaskManager.app and packages it as dist/TaskManager.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Task Manager"
EXECUTABLE="TaskManager"
BUNDLE_ID="com.example.TaskManager"
VERSION="1.0"
DIST="dist"
APP="$DIST/$APP_NAME.app"

# Universal binary if the toolchain supports it, otherwise native only.
if swift build -c release --arch arm64 --arch x86_64; then
    BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
    swift build -c release
    BIN_DIR="$(swift build -c release --show-bin-path)"
fi

rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
# The optional privileged helper. The app copies it to /Library only when the user installs it.
cp "$BIN_DIR/tmhelper" "$APP/Contents/MacOS/tmhelper"
cp -R LICENSES "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so the app launches on Apple Silicon.
codesign --force --sign - "$APP/Contents/MacOS/tmhelper"
codesign --force --sign - "$APP"

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DIST/TaskManager.dmg"
rm -rf "$STAGING"

echo "Created $DIST/TaskManager.dmg"
