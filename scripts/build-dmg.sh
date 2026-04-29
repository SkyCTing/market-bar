#!/bin/bash
set -euo pipefail

APP_NAME="GoldPriceBar"
BUNDLE_ID="com.goldpricebar.app"
VERSION="1.0.2"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build"
DIST_DIR="${PROJECT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
DMG_NAME="${APP_NAME}-${VERSION}"

echo "🔨 Building release binary..."
cd "${PROJECT_DIR}"
swift build -c release 2>&1

BINARY_PATH="${BUILD_DIR}/release/goldPriceBar"
if [ ! -f "${BINARY_PATH}" ]; then
    echo "❌ Binary not found at ${BINARY_PATH}"
    exit 1
fi
echo "✅ Binary built successfully"

# Clean previous dist
rm -rf "${DIST_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

echo "📦 Creating app bundle..."

# Copy binary
cp "${BINARY_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Copy icon
ICON_PATH="${PROJECT_DIR}/AppIcon.icns"
if [ -f "${ICON_PATH}" ]; then
    cp "${ICON_PATH}" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
    echo "✅ App icon copied"
else
    echo "⚠️  AppIcon.icns not found, skipping icon"
fi

# Create Info.plist
cat > "${APP_BUNDLE}/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Gold Price Bar</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

echo "✅ App bundle created at ${APP_BUNDLE}"

# Create DMG
echo "💿 Creating DMG..."

DMG_TEMP="${DIST_DIR}/dmg-staging"
DMG_PATH="${DIST_DIR}/${DMG_NAME}.dmg"

rm -rf "${DMG_TEMP}"
mkdir -p "${DMG_TEMP}"

# Copy app to staging
cp -R "${APP_BUNDLE}" "${DMG_TEMP}/"

# Create symlink to Applications folder
ln -s /Applications "${DMG_TEMP}/Applications"

# Create DMG
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_TEMP}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}" 2>&1

rm -rf "${DMG_TEMP}"

echo ""
echo "🎉 Done! DMG created at:"
echo "   ${DMG_PATH}"
echo ""
echo "📋 App bundle location:"
echo "   ${APP_BUNDLE}"
