#!/bin/bash
# Publish a new version of Bible Lookup: build, sign and notarize it, then put the
# installer and the update list (appcast.xml) on a new GitHub release. Copies of the
# app already installed find it there and offer to update themselves (Sparkle).
#
#   VERSION=1.2 BUILD=15 scripts/release.sh notes.md
#
#   VERSION   the version people see (1.2)
#   BUILD     a whole number higher than the last release's; updates go by this
#   notes.md  optional release notes: short paragraphs and "- " bullet lines. They
#             appear in the update window and on the GitHub release page.
#
# Needs the "BibleLookup" notarytool profile and the Sparkle update-signing key in
# this Mac's keychain (made with Sparkle's generate_keys). Settings for testing:
#   PUBLISH=0        build everything in dist/updates but don't touch GitHub
#   DOWNLOAD_PREFIX  where the update list says to download from (default: the release)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?Set VERSION, e.g. VERSION=1.2}"
: "${BUILD:?Set BUILD to a whole number higher than the last release}"
NOTES=${1:-}
REPO=davidluttrull/bible-lookup-mac
TAG=v$VERSION
PUBLISH=${PUBLISH:-1}
export NOTARY_PROFILE=${NOTARY_PROFILE:-BibleLookup}
export SCRATCH=${SCRATCH:-$HOME/Library/Caches/BibleLookupBuild}
DOWNLOAD_PREFIX=${DOWNLOAD_PREFIX:-https://github.com/$REPO/releases/download/$TAG/}
SPARKLE_BIN="$SCRATCH/artifacts/sparkle/Sparkle/bin"
DMG="dist/BibleLookup-$VERSION.dmg"
UPDATES=dist/updates

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "!! $*"; exit 1; }

[ -z "$NOTES" ] || [ -f "$NOTES" ] || fail "No release notes file at $NOTES"
[[ "$BUILD" =~ ^[0-9]+$ ]] || fail "BUILD must be a whole number"

if [ "$PUBLISH" = 1 ]; then
  step "Checking before publishing"
  [ -z "$(git status --porcelain)" ] || fail "Commit your changes first (git status shows some)."
  gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && fail "Release $TAG already exists."
  LAST=$(curl -fsL "https://github.com/$REPO/releases/latest/download/appcast.xml" 2>/dev/null |
    sed -n 's/.*<sparkle:version>\([0-9]*\)<.*/\1/p' | head -1 || true)
  if [ -n "$LAST" ] && [ "$BUILD" -le "$LAST" ]; then
    fail "BUILD $BUILD isn't higher than the latest release's ($LAST), so nobody would be offered it."
  fi
  echo "   latest published build: ${LAST:-none}; this one: $BUILD"
fi

VERSION=$VERSION BUILD=$BUILD scripts/build.sh

step "Making the update list"
rm -rf "$UPDATES"
mkdir -p "$UPDATES"
cp "$DMG" "$UPDATES/"
if [ -n "$NOTES" ]; then
  # notes.md -> BibleLookup-<version>.html beside the download; generate_appcast embeds it
  python3 - "$NOTES" "$UPDATES/BibleLookup-$VERSION.html" <<'PY'
import html, re, sys
out, items = [], []
def inline(t):
    return re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", html.escape(t))
def flush():
    global items
    if items:
        out.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
        items = []
for para in open(sys.argv[1], encoding="utf-8").read().split("\n\n"):
    lines = [l.strip() for l in para.strip().splitlines() if l.strip()]
    for l in lines:
        if l.startswith(("- ", "* ")):
            items.append(l[2:])
        else:
            flush()
            out.append(f"<p>{inline(l)}</p>")
    flush()
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
fi
# signs the download with the update key from the keychain (macOS may ask to allow it)
"$SPARKLE_BIN/generate_appcast" --embed-release-notes --download-url-prefix "$DOWNLOAD_PREFIX" \
  --link "https://github.com/$REPO" -o "$UPDATES/appcast.xml" "$UPDATES"
grep -E "<sparkle:version>|<sparkle:shortVersionString>|url=" "$UPDATES/appcast.xml" | sed 's/^ */   /'

if [ "$PUBLISH" != 1 ]; then
  echo
  echo "Built $DMG and $UPDATES/appcast.xml (not published: PUBLISH=0)."
  exit 0
fi

step "Publishing $TAG on GitHub"
git push -q origin HEAD
NOTES_ARGS=(--notes "Bible Lookup $VERSION. Download $(basename "$DMG"), open it, and drag Bible Lookup to Applications. Copies already installed will offer to update themselves.")
[ -n "$NOTES" ] && NOTES_ARGS=(--notes-file "$NOTES")
gh release create "$TAG" "$DMG" "$UPDATES/appcast.xml" --repo "$REPO" --target "$(git rev-parse HEAD)" \
  --title "Bible Lookup $VERSION" "${NOTES_ARGS[@]}"
echo
echo "Published: https://github.com/$REPO/releases/tag/$TAG"
