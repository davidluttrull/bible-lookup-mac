#!/bin/bash
# Build "Bible Lookup.app" and a signed "drag to Applications" disk image in dist/.
#
#   scripts/build.sh
#
# Signing uses the keychain's "Developer ID Application" certificate. With
# NOTARY_PROFILE set, the app and the disk image are also notarized by Apple and
# stapled, so they open on any Mac without a warning:
#
#   NOTARY_PROFILE=<profile> scripts/build.sh
#
# (<profile> is a notarytool keychain profile, made once with
#  xcrun notarytool store-credentials <profile> --apple-id <you> --team-id <team>)
#
# Optional settings:
#   SIGN_IDENTITY   another signing identity ("-" = ad hoc, for testing on this Mac only)
#   VERSION, BUILD  version shown in Finder (default 1.0, 1)
#   BUNDLE_ID       default org.indianachristianacademy.BibleLookup
#   SKIP_TESTS=1    don't run the test suite first
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

BUNDLE_ID=${BUNDLE_ID:-org.indianachristianacademy.BibleLookup}
VERSION=${VERSION:-1.0}
BUILD=${BUILD:-1}
DIST=$ROOT/dist
APP="$DIST/Bible Lookup.app"
DMG="$DIST/Bible Lookup $VERSION.dmg"
# SwiftPM's build folder lives outside Documents: iCloud syncing upsets its database
SCRATCH=${SCRATCH:-$HOME/Library/Caches/BibleLookupBuild}

step() { printf '\n==> %s\n' "$*"; }

if [ -z "${SKIP_TESTS:-}" ]; then
  step "Running tests"
  LOG=$(mktemp)
  if ! swift test --scratch-path "$SCRATCH" > "$LOG" 2>&1; then
    grep -E "error|failed" "$LOG" | head -20
    echo "Tests failed (full log: $LOG)."
    exit 1
  fi
  grep -E "Executed [0-9]+ tests" "$LOG" | tail -1
  rm -f "$LOG"
fi

step "Building (Apple silicon + Intel)"
BUILD_ARGS=(-c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH" --product BibleLookup)
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/BibleLookup"

step "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BibleLookup"
sed -e "s/\$(BUNDLE_ID)/$BUNDLE_ID/" -e "s/\$(VERSION)/$VERSION/" -e "s/\$(BUILD)/$BUILD/" \
  Packaging/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/Web Resources/Data "$APP/Contents/Resources/"
xattr -cr "$APP"

if [ -z "${SIGN_IDENTITY:-}" ]; then
  SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
fi
if [ -z "$SIGN_IDENTITY" ]; then
  echo
  echo "!! No \"Developer ID Application\" certificate in the keychain."
  echo "!! Signing ad hoc: the app runs on this Mac, but other Macs will block it."
  echo "!! Create the certificate in Xcode > Settings > Accounts > Manage Certificates, then build again."
  SIGN_IDENTITY="-"
fi
ADHOC=0
[ "$SIGN_IDENTITY" = "-" ] && ADHOC=1

step "Signing with: $SIGN_IDENTITY"
SIGN=(codesign --force --sign "$SIGN_IDENTITY" --options runtime)
[ $ADHOC -eq 0 ] && SIGN+=(--timestamp)
"${SIGN[@]}" --entitlements Packaging/BibleLookup.entitlements "$APP"
codesign --verify --strict --verbose=1 "$APP"

notarize() {
  local file=$1 out id
  out=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
  echo "$out" | grep -E "id:|status:" | sed 's/^/   /'
  if ! echo "$out" | grep -q "status: Accepted"; then
    id=$(echo "$out" | sed -n 's/^ *id: *//p' | head -1)
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
    echo "Notarization failed for $file"
    exit 1
  fi
}

NOTARIZE=0
if [ $ADHOC -eq 0 ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARIZE=1
  step "Notarizing the app (a few minutes)"
  ZIP="$DIST/notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
fi

step "Making the disk image"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Bible Lookup" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
if [ $ADHOC -eq 0 ]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi

if [ $NOTARIZE -eq 1 ]; then
  step "Notarizing the disk image"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
fi

step "Checking what Gatekeeper will say"
spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/   /' || true
[ $ADHOC -eq 0 ] && { spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 | sed 's/^/   /' || true; }

echo
echo "Done: $DMG"
if [ $ADHOC -eq 1 ]; then
  echo "(ad hoc signature: for testing on this Mac only)"
elif [ $NOTARIZE -eq 0 ]; then
  echo "(signed but not notarized: set NOTARY_PROFILE to notarize)"
fi
