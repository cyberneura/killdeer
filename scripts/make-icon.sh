#!/usr/bin/env bash
# Renders packaging/AppIcon.svg to packaging/AppIcon.png, the master every icns
# slot is made from.
#
# Run by hand when the icon changes, and commit the png. It is not part of
# make-app.sh because that would put librsvg on the critical path of every
# release build, on a runner where the icon has not changed since the last one.
#
# The png is therefore a generated file that is committed, and the two can drift.
# If the app ships an icon that does not match the svg, this is why: run this.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v rsvg-convert >/dev/null; then
  echo "Error: rsvg-convert is not installed. brew install librsvg" >&2
  exit 1
fi

# 1024 rather than 512 so that the icon_512x512@2x slot is a straight copy
# instead of an upscale.
rsvg-convert -w 1024 -h 1024 packaging/AppIcon.svg -o packaging/AppIcon.png
echo "Wrote packaging/AppIcon.png"
