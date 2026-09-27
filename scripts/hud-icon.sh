#!/bin/zsh
# hud-icon.sh <repo> [target-repo-dir] [--preview <file.png>]
#
# Renders a MacHUD family icon (hudkit/Icons/<repo>.svg, or Icons/template.svg with a warning
# when the repo has none yet) into the app repo's bundle resources, see Icons/README.md:
#   Sources/<Product>/Resources/AppIcon.icns          16-512 pt, @1x and @2x (16-1024 px)
#   Sources/<Product>/Resources/MenuBarIcon.png       18x18 template glyph, black on clear
#   Sources/<Product>/Resources/MenuBarIcon@2x.png    36x36
# <Product> is the directory under Sources/ whose Resources/ holds Info.plist.
# --preview writes a check sheet: the tile at 16, 32, 44, 64 and 128 px, and the menu bar
# glyph at 18 and 36 px on light and dark bars.
#
# Needs rsvg-convert and ImageMagick (brew install librsvg imagemagick) and iconutil.
set -euo pipefail

usage() { print -u2 "usage: hud-icon.sh <repo> [target-repo-dir] [--preview <file.png>]"; exit 2; }
[[ $# -lt 1 || "$1" == -h || "$1" == --help ]] && usage
REPO="$1"; shift
TARGET="."
PREVIEW=""
while (( $# )); do
  case "$1" in
    --preview) PREVIEW="${2:?}"; shift 2 ;;
    -*) usage ;;
    *) TARGET="$1"; shift ;;
  esac
done
HUDKIT="${0:A:h:h}"
SVG="$HUDKIT/Icons/$REPO.svg"
if [[ ! -f "$SVG" ]]; then
  print -u2 "hud-icon: no Icons/$REPO.svg; using the placeholder Icons/template.svg"
  SVG="$HUDKIT/Icons/template.svg"
fi
for tool in rsvg-convert magick iconutil; do
  command -v $tool >/dev/null || { print -u2 "hud-icon: $tool not found"; exit 1; }
done

TARGET="${TARGET:A}"
PLISTS=("$TARGET"/Sources/*/Resources/Info.plist(N))
(( ${#PLISTS} == 1 )) || { print -u2 "hud-icon: expected one Sources/<Product>/Resources/Info.plist in $TARGET"; exit 1; }
RES="${PLISTS[1]:h}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The glyph's stroke is 60 units on the 1024 grid, under 1 px at 16 px; small renderings
# get a heavier stroke so the glyph stays legible.
print -- '#glyph { stroke-width: 80px; }' > "$WORK/bold.css"
print -- '#glyph { stroke-width: 70px; }' > "$WORK/medium.css"
# Menu bar: the glyph alone, black, at SF Symbol-like weight.
print -- '#tile, #glow { display: none; } svg { color: #000000; } #glyph { stroke-width: 52px; }' > "$WORK/menubar.css"

render() {  # render <pixels> <out.png>
  local px=$1 out=$2 css=()
  if (( px <= 16 )); then css=(-s "$WORK/bold.css")
  elif (( px <= 32 )); then css=(-s "$WORK/medium.css"); fi
  # Render at 1024 and downsample: smoother than rasterising the blur at tiny sizes.
  rsvg-convert "${css[@]}" -w 1024 -h 1024 "$SVG" -o "$WORK/full.png"
  magick "$WORK/full.png" -filter Lanczos -resize "${px}x${px}" -strip "PNG32:$out"
}

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for pt in 16 32 128 256 512; do
  render $pt "$ICONSET/icon_${pt}x${pt}.png"
  render $((pt * 2)) "$ICONSET/icon_${pt}x${pt}@2x.png"
done
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"

# The glyph fits the central 480 units (272..752) of the grid.
rsvg-convert -s "$WORK/menubar.css" -w 1024 -h 1024 "$SVG" -o "$WORK/menubar-full.png"
magick "$WORK/menubar-full.png" -crop 480x480+272+272 +repage "$WORK/menubar-crop.png"
magick "$WORK/menubar-crop.png" -filter Lanczos -resize 36x36 -strip "PNG32:$RES/MenuBarIcon@2x.png"
magick "$WORK/menubar-crop.png" -filter Lanczos -resize 18x18 -strip "PNG32:$RES/MenuBarIcon.png"

if [[ -n "$PREVIEW" ]]; then
  for px in 16 32 44 64 128; do render $px "$WORK/p$px.png"; done
  magick -background '#D6D6D6' \
    \( "$WORK/p16.png" "$WORK/p32.png" "$WORK/p44.png" "$WORK/p64.png" "$WORK/p128.png" -gravity center +append \) \
    \( \( -size 60x24 xc:'#ECECEC' "$RES/MenuBarIcon.png" -gravity center -composite \) \
       \( -size 60x24 xc:'#2A2A2A' \( "$RES/MenuBarIcon.png" -channel RGB -negate +channel \) -gravity center -composite \) \
       \( -size 100x44 xc:'#ECECEC' "$RES/MenuBarIcon@2x.png" -gravity center -composite \) \
       \( -size 100x44 xc:'#2A2A2A' \( "$RES/MenuBarIcon@2x.png" -channel RGB -negate +channel \) -gravity center -composite \) \
       -gravity center +append \) \
    -gravity center -append +repage -alpha remove -alpha off "$PREVIEW"
  print -u2 "Preview: $PREVIEW"
fi
print -u2 "Icon: $RES/AppIcon.icns, $RES/MenuBarIcon.png, $RES/MenuBarIcon@2x.png (from ${SVG:t})"
