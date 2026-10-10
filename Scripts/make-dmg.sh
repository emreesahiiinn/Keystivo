#!/bin/bash
# Builds a Release Keystivo.app and packages it as a drag-to-install disk image:
#   dist/Keystivo-<version>.dmg  (Keystivo.app → Applications)
#
# Signing comes from Config/Local.xcconfig (see Scripts/make-signing-cert.sh).
#
# Window layout (background, icon positions) lives in the volume's .DS_Store.
# The first run arranges the window through Finder — which needs your terminal to
# be allowed to control Finder — and saves the result as Config/DMG/DS_Store.
# Later runs reuse that template and don't need Finder at all.
#
# Usage: Scripts/make-dmg.sh [--relayout]   (--relayout regenerates the template)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
VOLUME_NAME="Keystivo"
DERIVED="$ROOT/build/ReleaseDerivedData"
APP="$DERIVED/Build/Products/Release/Keystivo.app"
WORK="$ROOT/build/dmg"
STAGE="$WORK/stage"
DIST="$ROOT/dist"
BACKGROUND="$ROOT/Config/DMG/background.tiff"
LAYOUT_TEMPLATE="$ROOT/Config/DMG/DS_Store"
RELAYOUT=0
[ "${1:-}" = "--relayout" ] && RELAYOUT=1

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }

step "Building Release"
xcodebuild -project "$ROOT/Keystivo.xcodeproj" -scheme Keystivo -configuration Release \
    -derivedDataPath "$DERIVED" clean build 2>&1 | grep -E "error:|warning: .*Keystivo|BUILD" || true
[ -d "$APP" ] || { echo "✗ Build failed: $APP not found"; exit 1; }

step "Verifying signature"
codesign --verify --deep --strict "$APP"
AUTHORITY="$(codesign -dvv "$APP" 2>&1 | grep '^Authority=' | head -1 | cut -d= -f2 || true)"
if [ -z "$AUTHORITY" ]; then
    echo "⚠ Ad-hoc signed: macOS permissions will have to be granted again after every update."
    echo "  Run Scripts/make-signing-cert.sh once to sign with a stable local certificate."
    IDENTITY=""
else
    echo "✓ Signed by: $AUTHORITY"
    IDENTITY="$AUTHORITY"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
OUTPUT="$DIST/Keystivo-$VERSION.dmg"

step "Staging Keystivo $VERSION ($BUILD)"
rm -rf "${WORK:?}"
mkdir -p "$STAGE/.background" "$DIST"
ditto "$APP" "$STAGE/Keystivo.app"
ln -s /Applications "$STAGE/Applications"
cp "$BACKGROUND" "$STAGE/.background/background.tiff"

# A volume with the same name would confuse the Finder layout step.
if [ -d "/Volumes/$VOLUME_NAME" ]; then
    hdiutil detach "/Volumes/$VOLUME_NAME" -quiet -force || true
fi

step "Creating disk image"
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -quiet -volname "$VOLUME_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$WORK/rw.dmg"
DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$WORK/rw.dmg" 2>/dev/null | grep -E '^/dev/' | head -1 | awk '{print $1}')"
MOUNT="/Volumes/$VOLUME_NAME"

if [ -f "$LAYOUT_TEMPLATE" ] && [ "$RELAYOUT" = 0 ]; then
    step "Applying saved window layout"
    cp "$LAYOUT_TEMPLATE" "$MOUNT/.DS_Store"
    echo "✓ Layout from Config/DMG/DS_Store"
else
    step "Arranging the Finder window"
    if /usr/bin/osascript <<EOF 2>/dev/null
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 860, 548}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "Keystivo.app" of container window to {165, 190}
        set position of item "Applications" of container window to {495, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
    then
        sync
        sleep 1
        if [ -f "$MOUNT/.DS_Store" ]; then
            cp "$MOUNT/.DS_Store" "$LAYOUT_TEMPLATE"
            echo "✓ Window arranged; saved as Config/DMG/DS_Store for future builds"
        fi
    else
        echo "⚠ Couldn't control Finder (allow it in System Settings › Privacy & Security › Automation)."
        echo "  The disk image works, but its window won't be arranged."
    fi
fi

sync
rm -rf "${MOUNT:?}/.fseventsd"
hdiutil detach "$DEVICE" -quiet || hdiutil detach "$DEVICE" -quiet -force

step "Compressing"
rm -f "$OUTPUT"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT"
if [ -n "$IDENTITY" ]; then
    codesign --sign "$IDENTITY" "$OUTPUT"
fi
hdiutil verify -quiet "$OUTPUT"
rm -rf "${WORK:?}"

echo
echo "✓ $OUTPUT ($(du -h "$OUTPUT" | cut -f1 | tr -d ' '))"
echo "  Open it and drag Keystivo into Applications."
