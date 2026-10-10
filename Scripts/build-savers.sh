#!/bin/bash
# Builds Keystivo's macOS screen savers: one "Keystivo <Name>.saver" per design,
# from the KeystivoScreenSaver module sources plus Savers/SaverHost.swift.
#
# Each bundle is compiled with its own Swift module name, so several Keystivo
# savers can be loaded into the same screen saver process without clashing.
# Results are cached (by source hash) in build/savers, so unchanged builds are fast.
#
# Usage: Scripts/build-savers.sh OUTPUT_DIR [SIGNING_IDENTITY]
#   Called by the Keystivo app target ("Build Screen Savers" phase) with
#   OUTPUT_DIR = Keystivo.app/Contents/Library/Screen Savers.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:?usage: build-savers.sh OUTPUT_DIR [SIGNING_IDENTITY]}"
IDENTITY="${2:-}"
SOURCES="$ROOT/Packages/KeystivoKit/Sources/KeystivoScreenSaver"
HOST="$ROOT/Savers/SaverHost.swift"
THUMBNAILS="$ROOT/Savers/Thumbnails.swift"
CATALOG="$ROOT/Packages/KeystivoKit/Sources/KeystivoCore/Resources/Localizable.xcstrings"
CACHE="$ROOT/build/savers"
VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${CURRENT_PROJECT_VERSION:-1}"
STYLES=(aurora fluid nebula ocean synthwave flip analog rain minimal shuffle)
ARCHS=(arm64 x86_64)
MIN_OS="15.0"

# Run outside Xcode's environment for the package toolchain if needed.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(xcrun --sdk macosx -f swiftc)"
SWIFT_FLAGS=(-sdk "$SDK" -swift-version 6 -O -parse-as-library
    -default-isolation MainActor
    -enable-upcoming-feature NonisolatedNonsendingByDefault
    -enable-upcoming-feature InferIsolatedConformances)

stamp() {
    { cat "$0" "$HOST" "$THUMBNAILS" "$SOURCES"/*.swift; echo "$IDENTITY $VERSION $BUILD_NUMBER";
      python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["strings"]; print(json.dumps({k:v for k,v in d.items() if k.startswith("saver.style.")}, sort_keys=True))' "$CATALOG"
    } | shasum -a 256 | cut -d' ' -f1
}

bundle_name() {
    case "$1" in
        aurora) echo "Aurora";; fluid) echo "Fluid";; nebula) echo "Nebula";; ocean) echo "Ocean";;
        synthwave) echo "Synthwave";; flip) echo "Flip";; analog) echo "Analog";; rain) echo "Rain";;
        minimal) echo "Minimal";; shuffle) echo "Shuffle";;
    esac
}

STAMP="$(stamp)"
if [ ! -f "$CACHE/stamp" ] || [ "$(cat "$CACHE/stamp")" != "$STAMP" ] || [ ! -d "$CACHE/bundles" ]; then
    echo "Building screen savers…"
    rm -rf "${CACHE:?}"
    mkdir -p "$CACHE/work" "$CACHE/bundles"

    # Thumbnails for System Settings (host architecture only).
    "$SWIFTC" "${SWIFT_FLAGS[@]}" -target "$(uname -m)-apple-macos$MIN_OS" -module-name SaverThumbnails \
        "$SOURCES"/*.swift "$THUMBNAILS" -o "$CACHE/work/thumbnails"
    "$CACHE/work/thumbnails" "$CACHE/work/thumbs"

    # One binary per style and architecture, compiled in parallel.
    pids=()
    for style in "${STYLES[@]}"; do
        name="$(bundle_name "$style")"
        cat > "$CACHE/work/Principal-$style.swift" <<EOF
import Foundation
@objc(KeystivoSaver$name) final class KeystivoSaver$name: KeystivoSaverHost {
    override class var saverStyle: SaverStyle { .$style }
}
EOF
        for arch in "${ARCHS[@]}"; do
            "$SWIFTC" "${SWIFT_FLAGS[@]}" -target "$arch-apple-macos$MIN_OS" -module-name "KeystivoSaver$name" \
                -emit-library -Xlinker -install_name -Xlinker "@rpath/KeystivoSaver$name" \
                -framework ScreenSaver -framework SwiftUI -framework AppKit -framework Metal -framework QuartzCore \
                "$SOURCES"/*.swift "$HOST" "$CACHE/work/Principal-$style.swift" \
                -o "$CACHE/work/$style-$arch" &
            pids+=($!)
        done
    done
    for pid in "${pids[@]}"; do wait "$pid"; done

    for style in "${STYLES[@]}"; do
        name="$(bundle_name "$style")"
        bundle="$CACHE/bundles/Keystivo $name.saver"
        mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
        lipo -create $(for arch in "${ARCHS[@]}"; do echo "$CACHE/work/$style-$arch"; done) -output "$bundle/Contents/MacOS/Keystivo $name"
        cp "$CACHE/work/thumbs/$style/thumbnail.png" "$CACHE/work/thumbs/$style/thumbnail@2x.png" "$bundle/Contents/Resources/"
        cat > "$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>Keystivo $name</string>
	<key>CFBundleIdentifier</key><string>com.keystivo.Keystivo.saver.$style</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>Keystivo $name</string>
	<key>CFBundlePackageType</key><string>BNDL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
	<key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
	<key>NSPrincipalClass</key><string>KeystivoSaver$name</string>
	<key>NSHumanReadableCopyright</key><string>© 2026 Keystivo</string>
</dict>
</plist>
EOF
        # Localized names ("Keystivo Flip Saat", …) from the app's string catalog.
        python3 - "$CATALOG" "saver.style.$style" "$bundle/Contents/Resources" <<'PY'
import json, os, sys
catalog, key, resources = sys.argv[1:4]
entry = json.load(open(catalog))["strings"].get(key, {})
for lang, value in entry.get("localizations", {}).items():
    name = "Keystivo " + value["stringUnit"]["value"]
    folder = os.path.join(resources, f"{lang}.lproj")
    os.makedirs(folder, exist_ok=True)
    with open(os.path.join(folder, "InfoPlist.strings"), "w", encoding="utf-8") as f:
        f.write(f'CFBundleName = "{name}";\nCFBundleDisplayName = "{name}";\n')
PY
        if [ -n "$IDENTITY" ]; then
            codesign --force --sign "$IDENTITY" --timestamp=none "$bundle" >/dev/null 2>&1
        fi
    done
    rm -rf "${CACHE:?}/work"
    echo "$STAMP" > "$CACHE/stamp"
fi

mkdir -p "$OUTPUT"
# Drop designs that no longer exist (e.g. after a rename).
for existing in "$OUTPUT"/Keystivo\ *.saver; do
    [ -e "$existing" ] || continue
    keep=0
    for style in "${STYLES[@]}"; do [ "$(basename "$existing")" = "Keystivo $(bundle_name "$style").saver" ] && keep=1; done
    [ "$keep" = 1 ] || rm -rf "${existing:?}"
done
for style in "${STYLES[@]}"; do
    name="$(bundle_name "$style")"
    rm -rf "${OUTPUT:?}/Keystivo $name.saver"
    ditto "$CACHE/bundles/Keystivo $name.saver" "$OUTPUT/Keystivo $name.saver"
done
echo "Screen savers ready in $OUTPUT"
