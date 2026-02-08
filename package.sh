#!/bin/zsh

APP_NAME="KindleBro"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"
DMG_NAME="${APP_NAME}.dmg"
ICON_SRC="icon.png"
ICON_NAME="AppIcon"

# 1. Build
echo "Building..."
swift build -c release -Xswiftc -D -Xswiftc APP_BUNDLE

if [ $? -ne 0 ]; then
    echo "Build failed."
    exit 1
fi

# 2. Create .app structure
echo "Creating ${APP_BUNDLE}..."
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# 3. Copy Executable
cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/"

# 4. Copy Info.plist
cp Info.plist "${APP_BUNDLE}/Contents/"

# 5. Generate and copy app icon
if [ -f "$ICON_SRC" ]; then
    echo "Generating app icon from ${ICON_SRC}..."
    ICONSET_DIR="$(mktemp -d)/${ICON_NAME}.iconset"
    mkdir -p "$ICONSET_DIR"

    sips -s format png -z 16 16     "$ICON_SRC" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
    sips -s format png -z 32 32     "$ICON_SRC" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
    sips -s format png -z 32 32     "$ICON_SRC" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
    sips -s format png -z 64 64     "$ICON_SRC" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
    sips -s format png -z 128 128   "$ICON_SRC" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
    sips -s format png -z 256 256   "$ICON_SRC" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
    sips -s format png -z 256 256   "$ICON_SRC" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
    sips -s format png -z 512 512   "$ICON_SRC" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
    sips -s format png -z 512 512   "$ICON_SRC" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
    sips -s format png -z 1024 1024 "$ICON_SRC" --out "${ICONSET_DIR}/icon_512x512@2x.png" >/dev/null

    iconutil -c icns "$ICONSET_DIR" -o "${APP_BUNDLE}/Contents/Resources/${ICON_NAME}.icns"
    # Nudge Finder to refresh the app icon cache
    touch "${APP_BUNDLE}/Contents/Info.plist"
    touch "${APP_BUNDLE}"
else
    echo "Warning: ${ICON_SRC} not found; skipping icon generation."
fi

# 6. Sign (Ad-hoc) to run locally
echo "Signing..."
codesign --force --deep --sign - "${APP_BUNDLE}"

# 7. Create DMG
echo "Creating ${DMG_NAME}..."
rm -f "$DMG_NAME"
STAGING_DIR="$(mktemp -d)"
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING_DIR}" -ov -format UDZO "${DMG_NAME}"
rm -rf "${STAGING_DIR}"

echo "Done! Created ${DMG_NAME}"
