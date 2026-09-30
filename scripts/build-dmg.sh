#!/bin/bash
set -euo pipefail

APP_NAME="MarketBar"
BUNDLE_ID="com.marketbar.app"
VERSION="1.0.27"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/.build"
DIST_DIR="${PROJECT_DIR}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
DMG_NAME="${APP_NAME}-${VERSION}"

echo "🔨 Building release binary..."
cd "${PROJECT_DIR}"
swift build -c release 2>&1

BINARY_PATH="${BUILD_DIR}/release/MarketBar"
if [ ! -f "${BINARY_PATH}" ]; then
    echo "❌ Binary not found at ${BINARY_PATH}"
    exit 1
fi
echo "✅ Binary built successfully"

# Preserve earlier versioned DMGs instead of clearing the whole dist directory.
mkdir -p "${DIST_DIR}"
if [ -d "${APP_BUNDLE}" ]; then
    rm -r "${APP_BUNDLE}"
fi
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

# Copy floating character sprites. The app loads these from Bundle.main when
# running inside the packaged .app bundle.
CHARACTER_RESOURCES="${PROJECT_DIR}/Sources/MarketBar/Resources/FloatingCharacter"
if [ -d "${CHARACTER_RESOURCES}" ]; then
    cp -R "${CHARACTER_RESOURCES}" "${APP_BUNDLE}/Contents/Resources/"
    echo "✅ Floating character resources copied"
else
    echo "❌ Floating character resources not found at ${CHARACTER_RESOURCES}"
    exit 1
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
    <string>Market Bar</string>
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
codesign --force --deep --sign - "${APP_BUNDLE}"

# Create DMG
echo "💿 Creating DMG..."

DMG_PATH="${DIST_DIR}/${DMG_NAME}.dmg"

# 用 create-dmg 而不是裸 hdiutil：它能把窗口大小、图标位置、Applications 拖拽目标
# 都写进 DMG 里的 .DS_Store —— 那才是「打开就是一张拖拽示意图」的来源。
# 裸 hdiutil 只会给出一个默认排列的文件夹，能用但不好看。
if ! command -v create-dmg >/dev/null 2>&1; then
    echo "❌ 没装 create-dmg。装一下：brew install create-dmg"
    exit 1
fi

# create-dmg 不肯覆盖已存在的文件
rm -f "${DMG_PATH}"

# 160×320 的图标、窗口 600×420：左边放 App，右边放 Applications，
# 留出中间那段给用户一眼看出「把左边拖到右边」
create-dmg \
    --volname "${APP_NAME}" \
    --window-pos 200 120 \
    --window-size 600 420 \
    --icon-size 128 \
    --icon "${APP_NAME}.app" 150 210 \
    --hide-extension "${APP_NAME}.app" \
    --app-drop-link 450 210 \
    --no-internet-enable \
    "${DMG_PATH}" \
    "${APP_BUNDLE}" 2>&1

[ -f "${DMG_PATH}" ] || { echo "❌ DMG 没生成"; exit 1; }

echo ""
echo "🎉 Done! DMG created at:"
echo "   ${DMG_PATH}"
echo ""
echo "📋 App bundle location:"
echo "   ${APP_BUNDLE}"
