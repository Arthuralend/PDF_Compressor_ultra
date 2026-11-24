#!/usr/bin/env bash
# Builds the Mac App Store package: sandboxed "PDF Compressor Ultra.app" in a
# signed installer .pkg, ready for upload to App Store Connect.
#
# Environment:
#   BUNDLE_ID          bundle identifier registered in App Store Connect (required for a real build)
#   TEAM_ID            Apple Developer Team ID (10 characters)
#   APP_IDENTITY       "3rd Party Mac Developer Application: NAME (TEAM_ID)" or "Apple Distribution: NAME (TEAM_ID)"
#   INSTALLER_IDENTITY "3rd Party Mac Developer Installer: NAME (TEAM_ID)"
#   PROFILE            path to the Mac App Store provisioning profile (.provisionprofile)
#   VERSION            marketing version, e.g. 1.0.0
#   BUILD_NUMBER       must grow with every upload, e.g. 1, 2, 3 …
#   ARCH               arm64 (default) or "arm64 x86_64" for a universal build
#
# Without APP_IDENTITY a local test build is made (ad-hoc signature, sandbox on,
# unsigned pkg) — useful to check that the sandboxed app works.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
APP_NAME="PDF Compressor Ultra"
BUNDLE_ID="${BUNDLE_ID:-app.pdfcompressorultra}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCH="${ARCH:-arm64}"
OUT="dist/appstore"
APP="$OUT/$APP_NAME.app"

if [[ "$ARCH" == *x86_64* ]]; then ARCHS="arm64;x86_64" FORCE="${FORCE:-1}" ./Scripts/build_jpegli.sh
else ./Scripts/build_jpegli.sh; fi

ARCH_FLAGS=()
for a in $ARCH; do ARCH_FLAGS+=(--arch "$a"); done
swift build -c release "${ARCH_FLAGS[@]}" --product PDFCompressorUltra
BIN="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/PDFCompressorUltra" "$APP/Contents/MacOS/PDFCompressorUltra"
cp Resources/Credits.rtf "$APP/Contents/Resources/"

# Icon: asset catalog (required by the App Store) + .icns
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" \
  --platform macosx --minimum-deployment-target 13.0 --app-icon AppIcon \
  --output-partial-info-plist "$OUT/assets-info.plist" >/dev/null
[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] || cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>PDFCompressorUltra</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) PDF Compressor Ultra</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>PDF Document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

ENT="$OUT/app.entitlements"
if [[ -n "${APP_IDENTITY:-}" ]]; then
  : "${TEAM_ID:?TEAM_ID is required}" "${PROFILE:?PROFILE is required}" "${INSTALLER_IDENTITY:?INSTALLER_IDENTITY is required}"
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  IDS="<key>com.apple.application-identifier</key><string>$TEAM_ID.$BUNDLE_ID</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM_ID</string>"
  python3 - "$IDS" > "$ENT" <<'PY'
import sys; print(open("Resources/AppStore.entitlements.template").read().replace("__IDENTIFIERS__", sys.argv[1]))
PY
  codesign --force --timestamp --sign "$APP_IDENTITY" --entitlements "$ENT" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$OUT/PDF-Compressor-Ultra-$VERSION-$BUILD_NUMBER.pkg"
else
  echo "⚠️  APP_IDENTITY не задан — тестовая сборка (ad-hoc подпись, песочница включена)"
  sed 's/__IDENTIFIERS__//' Resources/AppStore.entitlements.template > "$ENT"
  codesign --force --sign - --entitlements "$ENT" "$APP"
  productbuild --component "$APP" /Applications "$OUT/PDF-Compressor-Ultra-$VERSION-$BUILD_NUMBER-unsigned.pkg"
fi
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -q "com.apple.security.app-sandbox" \
  || { echo "sandbox entitlement missing" >&2; exit 1; }
echo "✅ $ROOT/$OUT"
ls -la "$OUT"
