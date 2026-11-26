#!/bin/bash
# Renders the PWA's PNG icons (needs rsvg-convert, MacPorts librsvg); the results are committed.
#   icon-192/512.png         purpose "any": the rounded tile as is (res/icon/sofa-icon.svg)
#   icon-180.png             apple-touch-icon: full-bleed (iOS rounds it itself; a pre-rounded
#                            tile with a margin came out small on the Home Screen)
#   icon-maskable-512.png    purpose "maskable": the whole 1024 canvas of the full-bleed source,
#                            so the couch stays inside Android's 80 % safe circle
set -eu
repo="$(cd "$(dirname "$0")/../.." && pwd)"
out="$repo/pwa/static/icons"
full="$repo/res/icon/sofa-icon-fullbleed.svg"
for n in 192 512; do rsvg-convert -w $n -h $n "$repo/res/icon/sofa-icon.svg" -o "$out/icon-$n.png"; done
rsvg-convert -w 180 -h 180 "$full" -o "$out/icon-180.png"
tmp="$(mktemp -t sofa-icon)"
sed 's|width="824" height="824" viewBox="100 100 824 824"|width="1024" height="1024" viewBox="0 0 1024 1024"|' "$full" > "$tmp"
rsvg-convert -w 512 -h 512 "$tmp" -o "$out/icon-maskable-512.png"
rm -f "$tmp"
echo "icons ok"
