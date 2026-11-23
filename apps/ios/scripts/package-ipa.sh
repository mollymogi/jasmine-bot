#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
ARCHIVE_APP_DIR="${BUILD_DIR}/DerivedData/Build/Products/Release-iphoneos/JasmineBot.app"
PAYLOAD_DIR="${BUILD_DIR}/Payload"
OUT_IPA="${BUILD_DIR}/JasmineBotIOS.ipa"

echo "==> [1/4] Running JasmineMobileCore Swift 6 self-check & unit tests..."
swift run --package-path "${ROOT_DIR}/Packages/JasmineMobileCore" JasmineMobileCoreCheck
swift test --package-path "${ROOT_DIR}/Packages/JasmineMobileCore"

echo "==> [2/4] Generating JasmineBotIOS.xcodeproj via xcodegen..."
cd "${ROOT_DIR}"
xcodegen generate

echo "==> [3/4] Building Release iOS application..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

xcodebuild \
  -project "${ROOT_DIR}/JasmineBotIOS.xcodeproj" \
  -scheme JasmineBotIOS \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath "${BUILD_DIR}/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build

echo "==> [4/4] Packaging unsigned .ipa (for AltStore / SideStore / Sideloadly / Developer re-signing)..."
plutil -extract NSSpeechRecognitionUsageDescription raw -o - "${ARCHIVE_APP_DIR}/Info.plist" >/dev/null
plutil -extract NSCameraUsageDescription raw -o - "${ARCHIVE_APP_DIR}/Info.plist" >/dev/null
plutil -extract NSAppTransportSecurity xml1 -o - "${ARCHIVE_APP_DIR}/Info.plist" >/dev/null
plutil -extract CFBundleIdentifier raw -o - "${ARCHIVE_APP_DIR}/Info.plist" >/dev/null
executable="$(plutil -extract CFBundleExecutable raw -o - "${ARCHIVE_APP_DIR}/Info.plist")"
test -x "${ARCHIVE_APP_DIR}/${executable}"
mkdir -p "${PAYLOAD_DIR}"
cp -R "${ARCHIVE_APP_DIR}" "${PAYLOAD_DIR}/"
(cd "${BUILD_DIR}" && zip -qr "${OUT_IPA}" Payload)
rm -rf "${PAYLOAD_DIR}"

echo "✅ Built IPA: ${OUT_IPA}"
