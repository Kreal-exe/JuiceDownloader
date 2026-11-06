#!/bin/bash
# Builds JuiceDownloader for macOS (native Objective-C / AppKit, MacApp/), installs it into /Applications, clears the
# quarantine flag and opens it.
#
#   ./build.sh           build, install into /Applications and open the app
#   ./build.sh --test    run the core tests first (catalog, paths, lyrics matching, ID3, downloads against a stub)
#   ./build.sh --dmg     also write dist/JuiceDownloader-macOS-v<version>.dmg for a release
#
# INSTALL_DIR=~/Applications ./build.sh installs somewhere else. Only the Xcode Command Line Tools are needed.
# The version is the <Version> of src/JuiceDownloader/JuiceDownloader.csproj, shared with the Windows app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
MAC="$ROOT/MacApp"
NAME="JuiceDownloader"
BUNDLE_ID="io.github.kreal-exe.JuiceDownloader"
VERSION="$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' "$ROOT/src/JuiceDownloader/JuiceDownloader.csproj" | head -1)"
DEST="${INSTALL_DIR:-/Applications}"
TEST=0
DMG=0
for arg in "$@"; do
  case "$arg" in
    --test) TEST=1 ;;
    --dmg)  DMG=1 ;;
    *) sed -n '2,9p' "$0"; exit 1 ;;
  esac
done

SDK="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --sdk macosx --find clang)"
CFLAGS=(-fobjc-arc -O2 -Wall -Wno-unused-parameter -mmacosx-version-min=12.0 -isysroot "$SDK")

# Build outside the project: synced folders (iCloud Documents) attach extended
# attributes to everything, and codesign refuses bundles that carry them.
OUT="$(mktemp -d -t juicedownloader)"
trap 'rm -rf "$OUT"' EXIT
APP="$OUT/$NAME.app"

if [ "$TEST" = 1 ]; then
  echo "Running the core tests..."
  # The non-UI core only: it needs no window server.
  "$CLANG" "${CFLAGS[@]}" -I"$MAC/Sources" -framework Foundation \
    "$MAC/Sources/CCCore.m" "$MAC/Sources/CCCatalog.m" "$MAC/Sources/CCLyrics.m" "$MAC/Sources/CCDownload.m" \
    "$MAC/Sources/CCWebLyrics.m" "$MAC/Sources/CCSongRules.m" "$MAC/Sources/CCLibrary.m" "$MAC/Sources/CCSettings.m" \
    "$MAC/Tests/CoreTests.m" -o "$OUT/core-tests"
  JUICEDOWNLOADER_STRINGS="$ROOT/src/JuiceDownloader/Localization/Strings:$MAC/Resources/Strings" \
    JUICEDOWNLOADER_FIXTURES="$ROOT/tests/fixtures" "$OUT/core-tests"
fi

echo "Building JuiceDownloader $VERSION for macOS..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Strings" "$APP/Contents/Resources/Strings-mac"
"$CLANG" "${CFLAGS[@]}" -arch arm64 -arch x86_64 \
  -framework Cocoa -framework QuartzCore -framework CoreImage -framework AVFoundation -framework AVKit -framework CoreMedia -framework ImageIO \
  "$MAC"/Sources/*.m -o "$APP/Contents/MacOS/$NAME"

cp "$MAC/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-$VERSION}" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$MAC/Resources/AppIcon.icns" "$MAC/Resources/logo.png" "$APP/Contents/Resources/"
# The Windows app's translations, then the macOS wording laid over them.
cp "$ROOT"/src/JuiceDownloader/Localization/Strings/*.json "$APP/Contents/Resources/Strings/"
cp "$MAC"/Resources/Strings/*.json "$APP/Contents/Resources/Strings-mac/"
# One empty .lproj per language, so system panels (Open, menus) follow the language list.
for json in "$MAC"/Resources/Strings/*.json; do mkdir -p "$APP/Contents/Resources/$(basename "$json" .json).lproj"; done
# Files copied out of iCloud Drive keep its attributes, which codesign refuses.
xattr -cr "$APP"

# Ad-hoc signature: required on Apple Silicon, and keeps the bundle intact in the disk image.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
codesign --verify --strict "$APP"

if [ "$DMG" = 1 ]; then
  # The app next to a link to Applications: open the image, drag one onto the other. The script next to them clears
  # the quarantine flag the download put on the unnotarized app (copying it to Applications first if needed) and opens it.
  STAGE="$OUT/dmg"
  mkdir -p "$STAGE" "$ROOT/dist"
  ditto "$APP" "$STAGE/$NAME.app"
  ln -s /Applications "$STAGE/Applications"
  cat > "$STAGE/Allow JuiceDownloader to open.command" <<'SCRIPT'
#!/bin/bash
# Clears the quarantine flag from JuiceDownloader in Applications so it opens with a double-click.
# Copies it there from this disk image first when it is not installed yet.
APP="/Applications/JuiceDownloader.app"
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ ! -d "$APP" ]; then
  echo "Copying JuiceDownloader to Applications..."
  ditto "$HERE/JuiceDownloader.app" "$APP" || { echo "Could not copy it. Drag JuiceDownloader onto Applications, then run this again."; exit 1; }
fi
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || sudo xattr -dr com.apple.quarantine "$APP"
echo "Done: JuiceDownloader is allowed to open."
open "$APP"
SCRIPT
  chmod +x "$STAGE/Allow JuiceDownloader to open.command"
  DMGFILE="$ROOT/dist/$NAME-macOS-v$VERSION.dmg"
  rm -f "$DMGFILE"
  hdiutil create -volname "$NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMGFILE" >/dev/null
  echo "Release disk image: $DMGFILE"
fi

# Quit a running copy first; if it refuses, leave the installed version alone.
if pgrep -f "$DEST/$NAME.app/Contents/MacOS/" >/dev/null 2>&1; then
  echo "Quitting the running JuiceDownloader..."
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    pgrep -f "$DEST/$NAME.app/Contents/MacOS/" >/dev/null 2>&1 || break
    sleep 0.2
  done
  if pgrep -f "$DEST/$NAME.app/Contents/MacOS/" >/dev/null 2>&1; then
    echo "JuiceDownloader is still running. Quit it and run the build again." >&2
    exit 1
  fi
fi

mkdir -p "$DEST"
rm -rf "$DEST/$NAME.app"
ditto "$APP" "$DEST/$NAME.app"
# A copy that came through a browser or AirDrop carries the quarantine flag; Gatekeeper would refuse the
# unnotarized app. Clearing it here makes the installed copy open with a double-click.
xattr -dr com.apple.quarantine "$DEST/$NAME.app" 2>/dev/null || true
echo "Installed: $DEST/$NAME.app"

# Opened right away, except on a CI runner or with NO_OPEN=1.
[ -n "${CI:-}${NO_OPEN:-}" ] || open "$DEST/$NAME.app"
exit 0
