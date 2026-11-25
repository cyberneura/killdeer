#!/usr/bin/env bash
# Builds Killdeer from this checkout, signs and notarizes it, and installs it
# in /Applications in place of the copy that is there.
#
#   scripts/local-deploy.sh
#   DEST_DIR="$HOME/Applications" scripts/local-deploy.sh
#   SIGN_IDENTITY="Developer ID Application: ..." NOTARY_PROFILE=name scripts/local-deploy.sh
#
# For running what is on this branch as the everyday app before it is released.
# Signed and notarized as a release is, so that what ends up installed differs
# from a release only in where it was built.
#
# Needs the Developer ID certificate in the keychain and a notarytool keychain
# profile (xcrun notarytool store-credentials). A running Killdeer is not
# stopped: it keeps running the old build until it is quit and opened again.
set -euo pipefail

cd "$(dirname "$0")/.."

# The settings are environment variables, unlike the --sign of make-app.sh.
# An argument that was quietly ignored would deploy with the defaults.
if [ $# -gt 0 ]; then
  echo "Usage: [SIGN_IDENTITY=...] [NOTARY_PROFILE=...] [DEST_DIR=...] scripts/local-deploy.sh" >&2
  exit 1
fi

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Cyberneura K.K. (2YN5TLNQ9J)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-cyberneura-notary}"
DEST_DIR="${DEST_DIR:-/Applications}"
if [ ! -d "$DEST_DIR" ]; then
  echo "Error: $DEST_DIR is not a directory." >&2
  exit 1
fi
DEST_DIR=$(cd "$DEST_DIR" && pwd -P)

APP="$PWD/dist/Killdeer.app"
DEST="$DEST_DIR/Killdeer.app"
# make-app.sh starts by deleting dist/Killdeer.app. Were that the installed
# copy, it would be gone before there was anything to put in its place.
# Compared as directories and not as text: dist may be a link.
if [ "$APP" = "$DEST" ] || { [ -e dist ] && [ dist -ef "$DEST_DIR" ]; }; then
  echo "Error: the build and the installation directory must differ." >&2
  exit 1
fi

# Asked before the build rather than after it: the build takes minutes, and
# missing credentials would otherwise be found out at the end of them.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "Error: notarytool cannot use the keychain profile '$NOTARY_PROFILE'." >&2
  echo "  Create it with: xcrun notarytool store-credentials $NOTARY_PROFILE" >&2
  exit 1
fi

scripts/make-app.sh --sign "$SIGN_IDENTITY"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")

WORK=$(mktemp -d)
STAGING=""
INSTALLED=""
cleanup() {
  # Every step is allowed to fail on its own. The trap runs under set -e, and
  # a temporary directory that would not delete must not be what stops the
  # previous app from being put back.
  rm -rf "$WORK" || true
  [ -n "$STAGING" ] || return 0
  if [ -z "$INSTALLED" ] && [ ! -e "$DEST" ] && [ ! -L "$DEST" ] &&
     { [ -e "$STAGING/previous.app" ] || [ -L "$STAGING/previous.app" ]; }; then
    if ! mv "$STAGING/previous.app" "$DEST"; then
      echo "Restore the previous app by hand from $STAGING/previous.app." >&2
      return 0
    fi
  fi
  if [ -z "$INSTALLED" ] && { [ -e "$STAGING/previous.app" ] || [ -L "$STAGING/previous.app" ]; }; then
    # Something else is at the destination and it is not this build. The
    # previous app is the only copy known to be good, so it is kept.
    echo "The previous app was kept at $STAGING/previous.app." >&2
    return 0
  fi
  rm -rf "$STAGING" || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

echo "Notarizing (this waits on Apple, usually a few minutes) ..."
ditto -c -k --keepParent "$APP" "$WORK/Killdeer.zip"
# Not stopped by a failed submission here: the result file holds Apple's
# answer, and the check below reports it instead of the script ending silent.
xcrun notarytool submit "$WORK/Killdeer.zip" --keychain-profile "$NOTARY_PROFILE" \
  --wait --output-format json > "$WORK/result.json" || true
STATUS=$(plutil -extract status raw -o - "$WORK/result.json" 2>/dev/null || true)
if [ "$STATUS" != "Accepted" ]; then
  echo "Error: notarization did not succeed (status: ${STATUS:-none})." >&2
  cat "$WORK/result.json" >&2 || true
  exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# Staged inside the destination so that the last step is a rename on one
# volume: the app is whole at its path or not there, never half copied.
STAGING=$(mktemp -d "$DEST_DIR/.killdeer-deploy.XXXXXX")
ditto "$APP" "$STAGING/Killdeer.app"
codesign --verify --deep --strict "$STAGING/Killdeer.app"
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  mv "$DEST" "$STAGING/previous.app"
fi
# mv onto a directory that exists moves the bundle inside it and calls that a
# success, which is what would happen if another deploy got here in between.
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
  echo "Error: $DEST appeared while it was being replaced." >&2
  exit 1
fi
mv "$STAGING/Killdeer.app" "$DEST"
if [ -e "$DEST/Killdeer.app" ] ||
   [ "$(plutil -extract CFBundleShortVersionString raw "$DEST/Contents/Info.plist" 2>/dev/null || true)" != "$VERSION" ]; then
  echo "Error: $DEST is not the build that was just made." >&2
  exit 1
fi
INSTALLED=1

echo "Installed Killdeer $VERSION: $DEST"
echo "Quit Killdeer from its menu and open it again to run this build."

# Two bundles with one identifier leave Launch Services free to open either,
# and the one in dist/ is now the copy nobody means. The install is done by
# this point, so failing to tidy up is said and not made an error.
rm -rf "$APP" || echo "Could not remove $APP; delete it by hand." >&2
