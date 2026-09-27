#!/bin/zsh
# hud-new-app.sh <repo> <Product> [parent-dir]
#
# Starts a MacHUD app repo from HUDKit's Templates/App: copies it to <parent-dir>/<repo>
# (default: the directory next to this HUDKit checkout, so ../hudkit resolves), replaces the
# placeholders, installs the CI workflow, runs git init and makes the first commit.
#
#   <repo>      lowercase: repo, socket, CLI and bundle-id suffix (e.g. ffmpeghud)
#   <Product>   the displayed name and Swift target prefix (e.g. ffmpegHUD)
#
# Placeholders: __REPO__, __REPO_UPPER__ (env var prefix), __PRODUCT__, __YEAR__, __DATE__,
# __AUTHOR__ (git config user.name).
set -euo pipefail

if [[ $# -lt 2 || "$1" == -h || "$1" == --help ]]; then
  print -u2 "usage: hud-new-app.sh <repo> <Product> [parent-dir]"
  exit 2
fi
REPO="$1"
PRODUCT="$2"
HUDKIT="${0:A:h:h}"
PARENT="${3:-${HUDKIT:h}}"
PARENT="${PARENT:A}"

[[ "$REPO" =~ '^[a-z][a-z0-9]*$' ]] || { print -u2 "hud-new-app: repo must be lowercase letters and digits ($REPO)"; exit 2; }
[[ "$PRODUCT" =~ '^[A-Za-z][A-Za-z0-9]*$' ]] || { print -u2 "hud-new-app: Product must be a Swift identifier ($PRODUCT)"; exit 2; }
[[ "${PRODUCT:l}" == "$REPO" ]] || print -u2 "hud-new-app: note: $PRODUCT lowercased is not $REPO (the convention is repo = lowercase Product)"

TEMPLATE="$HUDKIT/Templates/App"
DEST="$PARENT/$REPO"
[[ -e "$DEST" ]] && { print -u2 "hud-new-app: $DEST already exists"; exit 1; }
[[ -d "$PARENT/hudkit" ]] || print -u2 "hud-new-app: note: no $PARENT/hudkit; Package.swift expects HUDKit at ../hudkit"

UPPER="${REPO:u}"
YEAR="$(date +%Y)"
DATE="$(date +%Y-%m-%d)"
AUTHOR="$(git config user.name 2>/dev/null || true)"
AUTHOR="${AUTHOR:-$USER}"

mkdir -p "$PARENT"
ditto "$TEMPLATE" "$DEST"
rm -rf "$DEST/.build" "$DEST/build"

# Rename placeholder paths, deepest first.
find "$DEST" -depth -name '*__PRODUCT__*' | while IFS= read -r entry; do
  mv "$entry" "${entry:h}/${${entry:t}//__PRODUCT__/$PRODUCT}"
done

# Replace placeholders in file contents. __REPO_UPPER__ goes before __REPO__.
find "$DEST" -type f -not -path '*/.git/*' -print0 | while IFS= read -r -d '' file; do
  grep -Iq . "$file" 2>/dev/null || continue   # skip binaries and empty files
  REPO="$REPO" UPPER="$UPPER" PRODUCT="$PRODUCT" YEAR="$YEAR" DATE="$DATE" AUTHOR="$AUTHOR" \
    perl -pi -e 's/__REPO_UPPER__/$ENV{UPPER}/g; s/__REPO__/$ENV{REPO}/g; s/__PRODUCT__/$ENV{PRODUCT}/g; s/__YEAR__/$ENV{YEAR}/g; s/__DATE__/$ENV{DATE}/g; s/__AUTHOR__/$ENV{AUTHOR}/g' "$file"
done

mkdir -p "$DEST/.github/workflows"
cp "$HUDKIT/scripts/hud-ci.yml" "$DEST/.github/workflows/ci.yml"

if grep -rIl -e '__REPO' -e '__PRODUCT__' -e '__YEAR__' -e '__DATE__' -e '__AUTHOR__' "$DEST" >/dev/null 2>&1; then
  print -u2 "hud-new-app: placeholders left in:"
  grep -rIl -e '__REPO' -e '__PRODUCT__' -e '__YEAR__' -e '__DATE__' -e '__AUTHOR__' "$DEST" >&2
  exit 1
fi

git -C "$DEST" init -q -b main
git -C "$DEST" add -A
git -C "$DEST" commit -q -m "$PRODUCT 0.1.0 from the HUDKit app template"
print "Created $DEST"
print "Next: cd $DEST && swift test && ./build.sh"
