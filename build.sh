#!/bin/bash
set -euo pipefail

SCHEME="Glance"
CONFIG="Release"
BUILD_DIR="build"
APP_NAME="Glance"
PKG_NAME="Glance.pkg"

# Load signing config if available
if [ -f "build.env" ]; then
  source build.env
  echo "==> Loaded build.env (signed build)"
else
  echo "==> No build.env found (unsigned dev build)"
fi

echo "==> Generating Xcode project..."
xcodegen generate

# Build
APP_PATH="${BUILD_DIR}/Build/Products/${CONFIG}/${APP_NAME}.app"

if [ -n "${DEVELOPER_ID_APP:-}" ]; then
  echo "==> Building ${SCHEME} (${CONFIG}, signed)..."
  xcodebuild -project ${APP_NAME}.xcodeproj \
    -scheme ${SCHEME} \
    -configuration ${CONFIG} \
    -derivedDataPath ${BUILD_DIR} \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${DEVELOPER_ID_APP}" \
    DEVELOPMENT_TEAM="${TEAM_ID}" \
    OTHER_CODE_SIGN_FLAGS=--timestamp \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    build | tail -3
else
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
fi

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: Build failed, ${APP_PATH} not found"
  exit 1
fi

# Package PKG
echo "==> Packaging PKG..."
rm -f "${PKG_NAME}"

if [ -n "${DEVELOPER_ID_INSTALLER:-}" ]; then
  # Build unsigned, then sign with installer identity
  pkgbuild \
    --component "$APP_PATH" \
    --install-location /Applications \
    "${PKG_NAME}.unsigned"

  productsign \
    --sign "${DEVELOPER_ID_INSTALLER}" \
    "${PKG_NAME}.unsigned" \
    "${PKG_NAME}"

  rm -f "${PKG_NAME}.unsigned"
  echo "==> PKG signed with: ${DEVELOPER_ID_INSTALLER}"
else
  pkgbuild \
    --component "$APP_PATH" \
    --install-location /Applications \
    "${PKG_NAME}"
fi

# Notarize
if [ -n "${NOTARY_API_KEY:-}" ]; then
  echo "==> Notarizing PKG..."
  SUBMIT_OUTPUT=$(xcrun notarytool submit "${PKG_NAME}" \
    --key "${NOTARY_API_KEY}" \
    --key-id "${NOTARY_API_KEY_ID}" \
    --issuer "${NOTARY_API_ISSUER_ID}" \
    --wait 2>&1)

  echo "$SUBMIT_OUTPUT"

  # Extract submission ID and check result
  SUBMISSION_ID=$(echo "$SUBMIT_OUTPUT" | grep "id:" | head -1 | awk '{print $2}')

  if echo "$SUBMIT_OUTPUT" | grep -q "status: Invalid"; then
    echo "==> Notarization FAILED. Fetching log..."
    xcrun notarytool log "$SUBMISSION_ID" \
      --key "${NOTARY_API_KEY}" \
      --key-id "${NOTARY_API_KEY_ID}" \
      --issuer "${NOTARY_API_ISSUER_ID}"
    exit 1
  fi

  echo "==> Stapling ticket..."
  xcrun stapler staple "${PKG_NAME}"
else
  echo "==> Skipping notarization (no API key configured)"
fi

echo "==> Done!"
echo "    App: ${APP_PATH}"
echo "    PKG: ${PKG_NAME}"
echo ""
echo "To run directly:"
echo "    open ${APP_PATH}"
