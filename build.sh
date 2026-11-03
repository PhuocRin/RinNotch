#!/bin/bash
# Build RinNotch.app (universal: Mac chip Apple + Mac Intel) và file cài .dmg.
#   ./build.sh       → build/RinNotch.app
#   ./build.sh dmg   → build + build/RinNotch-X.Y.dmg
set -euo pipefail
export LC_ALL=en_US.UTF-8
cd "$(dirname "$0")"

APP="build/RinNotch.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"

echo "→ Đang build RinNotch ${VERSION}…"
xcrun swiftc --version 2>&1 | head -1
rm -rf build
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" build/obj

for ARCH in arm64 x86_64; do
  xcrun swiftc -O \
    -target "${ARCH}-apple-macos14.0" \
    Sources/main.swift \
    -o "build/obj/RinNotch-${ARCH}" \
    -swift-version 5 -parse-as-library \
    -framework Cocoa -framework SwiftUI -framework AVFoundation -framework CoreAudio \
    -framework IOKit -framework Carbon -framework ServiceManagement -framework UniformTypeIdentifiers -framework QuickLookThumbnailing
done
lipo -create build/obj/RinNotch-arm64 build/obj/RinNotch-x86_64 -output "${APP}/Contents/MacOS/RinNotch"
cp Info.plist "${APP}/Contents/Info.plist"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
  echo "⚠ Ký ad-hoc (bản thử)."
  codesign --force --sign - --identifier com.phuocrin.rinnotch "${APP}"
else
  codesign --force --timestamp=none --sign "${SIGN_IDENTITY}" \
    ${SIGN_KEYCHAIN:+--keychain "${SIGN_KEYCHAIN}"} \
    --identifier com.phuocrin.rinnotch "${APP}"
fi
codesign --verify --strict "${APP}"
codesign -d -r- "${APP}" 2>&1 | grep -i designated || true
echo "✓ Xong: ${APP}"

if [[ "${1:-}" == "dmg" ]]; then
  DMG="build/RinNotch-${VERSION}.dmg"
  STAGE="build/dmg"
  mkdir -p "${STAGE}"
  cp -R "${APP}" "${STAGE}/"
  ln -s /Applications "${STAGE}/Applications"
  hdiutil create -volname "RinNotch" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}"
  echo "✓ File cài: ${DMG}"
fi
