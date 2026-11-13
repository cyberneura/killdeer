#!/usr/bin/env bash
# Builds dist/Killdeer.app into dist/, ready to run or to be put in a dmg.
#
# SwiftPM produces bare executables, so the .app around them is assembled here:
# the universal binaries, packaging/icons/{icon.icns,Assets.car}, and
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

# The size-specific icon.icns and the matching asset catalog are committed and
# verified by scripts/generate-macos-icons.sh. A plain sips + iconutil pass would
# store 16/32px as PNG (icp4/icp5, which IconServices can miscolour) and leave
# no Assets.car, which gives Finder's list view a white frame on macOS 27.
cp packaging/icons/icon.icns packaging/icons/Assets.car "$APP/Contents/Resources/"

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
