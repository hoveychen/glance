#!/bin/bash
set -euo pipefail

SCHEME="Glance"
CONFIG="Release"
BUILD_DIR="build"
APP_NAME="Glance"
DMG_NAME="Glance.dmg"

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Building ${SCHEME} (${CONFIG}, dev)..."
xcodebuild -project ${APP_NAME}.xcodeproj \
  -scheme ${SCHEME} \
  -configuration ${CONFIG} \
  -derivedDataPath ${BUILD_DIR} \
  PRODUCT_BUNDLE_IDENTIFIER=com.hoveychen.Glance.dev \
  BUNDLE_DISPLAY_NAME="Glance Dev" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  build | tail -3

APP_PATH="${BUILD_DIR}/Build/Products/${CONFIG}/${APP_NAME}.app"

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: Build failed, ${APP_PATH} not found"
  exit 1
fi

echo "==> Packaging DMG..."
rm -rf dmg_contents "${DMG_NAME}"
mkdir -p dmg_contents
cp -R "$APP_PATH" dmg_contents/
ln -s /Applications dmg_contents/Applications

hdiutil create -volname "${APP_NAME}" \
  -srcfolder dmg_contents \
  -ov -format UDZO \
  "${DMG_NAME}" \
  -quiet

rm -rf dmg_contents

echo "==> Done!"
echo "    App: ${APP_PATH}"
echo "    DMG: ${DMG_NAME}"
echo ""
echo "To run directly:"
echo "    open ${APP_PATH}"
