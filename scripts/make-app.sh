#!/usr/bin/env bash
# Builds dist/Killdeer.app into dist/, ready to run or to be put in a dmg.
#
# SwiftPM produces bare executables, so the .app around them is assembled here:
# the universal binaries, an .icns made from packaging/AppIcon.png, and
# packaging/Info.plist with the version filled in from the VERSION file.
#
#   scripts/make-app.sh                        # unsigned; for local use
#   scripts/make-app.sh --sign "Developer ID Application: ..."
#
# Signing is what a release needs and what a local build has no way to do, so it
# is a flag rather than a step of its own. Nothing here talks to the network.
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sign)
      IDENTITY="${2:-}"
      if [ -z "$IDENTITY" ]; then
        echo "Error: --sign needs an identity." >&2
        exit 1
      fi
      shift 2
      ;;
    *)
      echo "Usage: scripts/make-app.sh [--sign <identity>]" >&2
      exit 1
      ;;
  esac
done

VERSION=$(tr -d '[:space:]' < VERSION)
if [ -z "$VERSION" ]; then
  echo "Error: VERSION is empty." >&2
  exit 1
fi

# Both architectures, so that the one dmg runs on Intel and Apple Silicon alike.
# The flags have to match on every swift invocation below: --show-bin-path
# answers for the flags it is given, and answering for a different build would
# hand back a path that holds the wrong binary (or nothing at all).
ARCHS=(--arch arm64 --arch x86_64)

echo "Building Killdeer $VERSION (universal) ..."
swift build -c release "${ARCHS[@]}"
BIN_PATH=$(swift build -c release "${ARCHS[@]}" --show-bin-path)

APP="dist/Killdeer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Both executables ride in the same bundle. The cask symlinks the cli out of
# Contents/MacOS into the Homebrew prefix, so a user who installs the app gets
# `killdeer` on their PATH without a second download to keep in step with it.
cp "$BIN_PATH/killdeer-app" "$APP/Contents/MacOS/killdeer-app"
cp "$BIN_PATH/killdeer" "$APP/Contents/MacOS/killdeer"

# Both architectures have to be in there. A single-architecture binary still
# runs on the machine that built it, so without this check the mistake would
# only show up on somebody else's Mac.
for binary in killdeer-app killdeer; do
  archs=$(lipo -archs "$APP/Contents/MacOS/$binary")
  case "$archs" in
    *arm64*) ;;
    *) echo "Error: $binary is missing arm64: $archs" >&2; exit 1 ;;
  esac
  case "$archs" in
    *x86_64*) ;;
    *) echo "Error: $binary is missing x86_64: $archs" >&2; exit 1 ;;
  esac
done

# The .icns is generated rather than committed: packaging/AppIcon.png is the
# master, and a second copy of it in another format is a second thing to keep in
# step. The master is 1024x1024, so the 512x512@2x slot is a straight copy and
# every other slot is a downscale.
ICONSET_ROOT=$(mktemp -d)
trap 'rm -rf "$ICONSET_ROOT"' EXIT
ICONSET="$ICONSET_ROOT/AppIcon.iconset"
mkdir -p "$ICONSET"
MASTER="packaging/AppIcon.png"
if [ ! -f "$MASTER" ]; then
  echo "Error: $MASTER is missing. Run scripts/make-icon.sh." >&2
  exit 1
fi
sips -z 16 16     "$MASTER" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     "$MASTER" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$MASTER" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     "$MASTER" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$MASTER" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   "$MASTER" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$MASTER" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   "$MASTER" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$MASTER" --out "$ICONSET/icon_512x512.png"    >/dev/null
sips -z 1024 1024 "$MASTER" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Matched with the element around it rather than on its own. The comment at the
# top of packaging/Info.plist names the placeholder to explain it, and a bare
# s/__VERSION__/0.2.4/ rewrote that sentence into nonsense in every shipped copy.
# The guard is narrowed the same way, or the comment would trip it every time.
sed "s|<string>__VERSION__</string>|<string>${VERSION}</string>|g" \
  packaging/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
if grep -q "<string>__VERSION__</string>" "$APP/Contents/Info.plist"; then
  echo "Error: the version placeholder is still in the Info.plist." >&2
  exit 1
fi

if [ -n "$IDENTITY" ]; then
  # Signed inside out. `killdeer` is a second Mach-O in Contents/MacOS, which
  # codesign treats as nested code: signing the bundle without having signed it
  # first seals a binary that carries no signature of its own, and notarization
  # rejects that.
  #
  # --options runtime (the hardened runtime) is what notarization requires, and
  # it is required on the nested binary too; --timestamp is what keeps the
  # signature valid after the certificate expires.
  echo "Signing with: $IDENTITY"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" \
    "$APP/Contents/MacOS/killdeer"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
fi

echo "Built $APP"
