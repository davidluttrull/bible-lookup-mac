# Bible Lookup for Mac

The Bible Lookup site as a Mac app. Type a reference (`John 3:16`, `jn 3:16-18`,
`Ps 23`, `James 1:5; John 3:16-18`), pick a translation, and press Return.

It is written in Swift and needs nothing else installed. The page you see is the
same HTML, CSS and JavaScript as the website. Swift code answers the page's
`/api` requests inside the app, so the app runs no web server and opens no
network port.

## Installing

Download the `.dmg` from the
[Releases page](https://github.com/davidluttrull/bible-lookup-mac/releases), open it,
and drag **Bible Lookup** to **Applications**. It needs macOS 13 or later and runs on
Apple silicon and Intel Macs.

From version 1.1 on, the app keeps itself up to date. It checks once a day, and
when there's a new version it offers to install it and restart. You can also
choose **Bible Lookup → Check for Updates…**, or turn automatic checks off in
Settings.

KJV and ASV are built in and work offline. NET and NLT work as soon as you are
online. For the rest, open **Bible Lookup → Settings** (⌘,):

| Translation | What to put in Settings |
|---|---|
| ESV | a free key from <https://api.esv.org/account/create-application/> |
| NLT | optional: your own key from <https://api.nlt.to/> (it works without one) |
| NIV, CSB, NASB | an API.Bible key from <https://api.bible>, then click **Find My Translations** |

Keys are saved in the Mac's keychain. The app ships with no keys, so each person
who installs it uses their own.

## Using it

- **⌘S** jumps to the search box (so does `/`).
- **←** and **→** go to the previous and next chapter.
- **⌘+**, **⌘−** and **⌘0** change the text size.
- **⌘P** prints the passage without the header and links.
- **⌘N** opens another window.
- **Open in Logos** links open Logos if it is installed. BibleGateway links open
  in your web browser.

## Building

You need Xcode (15 or later). Then run:

```
scripts/build.sh
```

The script runs the tests, builds for Apple silicon and Intel, signs the app
with the keychain's **Developer ID Application** certificate, and writes
`dist/Bible Lookup.app` and `dist/BibleLookup-<version>.dmg`.

To notarize (so other Macs open it without a warning), give it the notarytool
keychain profile saved on this Mac (named `BibleLookup`):

```
NOTARY_PROFILE=BibleLookup scripts/build.sh
```

The bundle ID is `org.indianachristianacademy.BibleLookup`; change it with
`BUNDLE_ID=...`.

## How it's put together

- `Sources/BibleLookupCore/`: what the Python server did.
  - `BibleRef.swift`: book names, abbreviations and reference parsing
  - `Parsers.swift`: turning each source's HTML into verses, section headings
    and titles
  - `Providers.swift`: fetching from ESV, NLT, NET and API.Bible, plus the
    bundled KJV and ASV
  - `Service.swift`: the `/api/config`, `/api/parse` and `/api/passage` answers
- `Sources/BibleLookup/`: the Mac app (window, menus, Settings, keychain).
- `Resources/Web/`: the page. `Resources/Data/`: the bundled KJV and ASV.
- `Packaging/`: Info.plist, the sandbox entitlements, and the icon artwork.
  `scripts/make-icon.swift` redraws `Resources/AppIcon.icns`.
- `python-reference/`: the Python version this app was ported from, with its
  tools for rebuilding the bundled Bibles from eBible.org's files.

## Privacy

The app sends each lookup only to that translation's own site. API.Bible asks
apps to report which passages are shown (its Fair Use Management System). The
app does this with a random device ID and no personal information.
