#!/bin/zsh
# Archive the Plandit app and upload it to TestFlight.
#
#   TEAM_ID=XXXXXXXXXX ./scripts/testflight.sh
#
# Needs: the paid Apple Developer team signed into Xcode (Settings → Accounts) so automatic
# signing can create the distribution certificate and profiles, and an App Store Connect app
# record for com.plandit.app. Optional: ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH for an
# App Store Connect API key, which lets the upload run without an interactive Xcode session.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${TEAM_ID:?Set TEAM_ID to the paid Apple Developer team id}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
OUT="${OUT:-$TMPDIR/plandit-testflight}"
ARCHIVE="$OUT/Plandit.xcarchive"
mkdir -p "$OUT"

AUTH=()
if [[ -n "${ASC_KEY_ID:-}" ]]; then
  AUTH=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")
fi

xcodegen generate >/dev/null

echo "→ Archiving (build $BUILD_NUMBER)…"
xcodebuild -project Plandit.xcodeproj -scheme Plandit -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates "${AUTH[@]}" \
  DEVELOPMENT_TEAM="$TEAM_ID" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  archive | grep -E "error:|warning: .*signing|ARCHIVE" || true
test -d "$ARCHIVE" || { echo "archive failed"; exit 1; }

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST

echo "→ Uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/ExportOptions.plist" \
  -exportPath "$OUT/export" -allowProvisioningUpdates "${AUTH[@]}" | grep -E "error:|EXPORT|Upload" || true
echo "Done. Apple processes the build for 10–30 minutes, then it appears under TestFlight."
