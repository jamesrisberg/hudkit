#!/bin/zsh
# hud-catalog.sh: edit MacHUD's app catalog, machud/site/catalog.json, and publish it.
#
#   hud-catalog.sh set <repo> <version> <url> <sha256> <size> [options]
#       add or update the app's entry. Metadata not given as an option is kept from the
#       existing entry, else read from the app repo (HUD_APP_DIR, default ../<repo> next to
#       HUDKit): id, name and minOS from Sources/*/Resources/Info.plist, kind from the first
#       panel in machud.json ("umbrella" for MacHUD), summary from the GitHub repo
#       description. bundled defaults to kind == hover.
#       Options: --id --name --kind windowed|hover|umbrella --summary --min-os
#                --bundled true|false --icon --homepage --published-at
#   hud-catalog.sh hudkit <version>
#       set the catalog's "hudkit" (the current HUDKit contract version)
#   hud-catalog.sh show
#       print the published catalog (origin/main)
#
# The edit happens in a temporary worktree of the machud repo at origin/main, is committed
# ("Catalog: <Name> <version>") and pushed to main, so a machud checkout with work in
# progress is never touched. GitHub Pages serves site/ at
# https://jamesrisberg.github.io/machud/catalog.json (.github/workflows/pages.yml in machud).
#
# Environment:
#   MACHUD_DIR           the machud checkout (default: ../machud next to HUDKit)
#   HUD_CATALOG_FILE     edit this file in place instead: no git, no push (testing)
#   HUD_CATALOG_NO_PUSH  commit in the temporary worktree but do not push; the commit is kept
#                        on the branch catalog/<timestamp>
#   HUD_COMMIT_TRAILER   a line appended to the commit message (e.g. a Co-Authored-By trailer)
#   HUD_GITHUB_OWNER     owner of the app repos (default jamesrisberg)
set -euo pipefail

HERE="${0:A:h}"
HUDKIT_DIR="${HERE:h}"
MACHUD_DIR="${MACHUD_DIR:-${HUDKIT_DIR:h}/machud}"
OWNER="${HUD_GITHUB_OWNER:-jamesrisberg}"
CATALOG_PATH="site/catalog.json"

usage() {
  print -u2 "usage: hud-catalog.sh set <repo> <version> <url> <sha256> <size> [--id ..] [--name ..] [--kind ..] [--summary ..] [--min-os ..] [--bundled true|false] [--icon ..] [--homepage ..] [--published-at ..]"
  print -u2 "       hud-catalog.sh hudkit <version>"
  print -u2 "       hud-catalog.sh show"
  exit 2
}
die() { print -u2 "hud-catalog: $*"; exit 1; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

(( $# >= 1 )) || usage
CMD="$1"; shift

if [[ "$CMD" == show ]]; then
  if [[ -n "${HUD_CATALOG_FILE-}" ]]; then cat "$HUD_CATALOG_FILE"; exit 0; fi
  git -C "$MACHUD_DIR" fetch -q origin main
  git -C "$MACHUD_DIR" show "origin/main:$CATALOG_PATH"
  exit 0
fi

# Builds the jq program and its arguments for the edit; sets SUBJECT.
typeset -a JQ_ARGS
JQ_PROG=""
SUBJECT=""

case "$CMD" in
  hudkit)
    (( $# == 1 )) || usage
    JQ_ARGS=(--arg v "$1" --arg now "$(now)")
    JQ_PROG='.hudkit = $v | .updatedAt = $now'
    SUBJECT="Catalog: HUDKit $1"
    ;;
  set)
    (( $# >= 5 )) || usage
    REPO="$1" VERSION="$2" URL="$3" SHA="$4" SIZE="$5"; shift 5
    [[ "$SIZE" == <-> ]] || die "size must be a byte count: $SIZE"
    [[ "$SHA" =~ ^[0-9a-f]{64}$ ]] || die "sha256 must be 64 hex digits"
    typeset -A opt
    while (( $# )); do
      case "$1" in
        --id|--name|--kind|--summary|--min-os|--bundled|--icon|--homepage|--published-at)
          (( $# >= 2 )) || usage; opt[${1#--}]="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    ;;
  *) usage ;;
esac

# The file to edit: HUD_CATALOG_FILE, or site/catalog.json in a fresh worktree at origin/main.
WT=""
cleanup() {
  if [[ -n "$WT" ]]; then
    git -C "$MACHUD_DIR" worktree remove --force "$WT" >/dev/null 2>&1 || true
    rm -rf "$WT"
  fi
}
trap cleanup EXIT

if [[ -n "${HUD_CATALOG_FILE-}" ]]; then
  FILE="$HUD_CATALOG_FILE"
else
  [[ -d "$MACHUD_DIR/.git" || -f "$MACHUD_DIR/.git" ]] || die "no machud checkout at $MACHUD_DIR (set MACHUD_DIR)"
  git -C "$MACHUD_DIR" fetch -q origin main
  WT="$(mktemp -d "${TMPDIR:-/tmp}/hud-catalog.XXXXXX")"
  git -C "$MACHUD_DIR" worktree add -q --detach "$WT" origin/main
  FILE="$WT/$CATALOG_PATH"
fi
[[ -f "$FILE" ]] || { mkdir -p "${FILE:h}"; print '{"schemaVersion":1,"updatedAt":"","hudkit":"","apps":[]}' > "$FILE"; }

if [[ "$CMD" == set ]]; then
  existing="$(jq --arg r "$REPO" '.apps[] | select(.repo == $r)' "$FILE")"
  field() { # field <key> [<existing json key>]: option, else existing entry, else empty
    local key="$1" jkey="${2:-$1}"
    if [[ -n "${opt[$key]-}" ]]; then print -r -- "${opt[$key]}"; return; fi
    [[ -n "$existing" ]] && print -r -- "$(jq -r --arg k "$jkey" '.[$k] // empty | tostring' <<<"$existing")"
    return 0
  }
  ID="$(field id)"; NAME="$(field name)"; KIND="$(field kind)"; SUMMARY="$(field summary)"
  MINOS="$(field min-os minOS)"; BUNDLED="$(field bundled)"; ICON="$(field icon)"; HOMEPAGE="$(field homepage)"

  # Anything still missing comes from the app repo.
  APP_DIR="${HUD_APP_DIR:-${HUDKIT_DIR:h}/$REPO}"
  PLIST="$(print -l "$APP_DIR"/Sources/*/Resources/Info.plist(N) | head -1)"
  MANIFEST="$(print -l "$APP_DIR"/Sources/*/Resources/machud.json(N) | head -1)"
  if [[ -n "$PLIST" ]]; then
    [[ -n "$ID" ]] || ID="$(plutil -extract CFBundleIdentifier raw -o - "$PLIST" 2>/dev/null || true)"
    [[ -n "$NAME" ]] || NAME="$(plutil -extract CFBundleName raw -o - "$PLIST" 2>/dev/null || true)"
    [[ -n "$MINOS" ]] || MINOS="$(plutil -extract LSMinimumSystemVersion raw -o - "$PLIST" 2>/dev/null || true)"
  fi
  if [[ -z "$KIND" ]]; then
    if [[ "$REPO" == machud ]]; then KIND=umbrella
    elif [[ -n "$MANIFEST" ]]; then KIND="$(jq -r '.panels[0].kind // "hover"' "$MANIFEST")"
    fi
  fi
  if [[ -z "$SUMMARY" ]]; then
    SUMMARY="$(gh repo view "$OWNER/$REPO" --json description -q .description 2>/dev/null || true)"
    # "Sift: an on-screen file manager ... (MacHUD app)" -> "An on-screen file manager ..."
    SUMMARY="${SUMMARY#*: }"; SUMMARY="${SUMMARY%" (MacHUD app)"}"
    SUMMARY="${(U)SUMMARY[1]}${SUMMARY[2,-1]}"
  fi
  [[ -n "$BUNDLED" ]] || { [[ "$KIND" == hover ]] && BUNDLED=true || BUNDLED=false; }
  [[ -n "$ICON" ]] || ICON="https://$OWNER.github.io/machud/icons/$REPO.png"
  [[ -n "$HOMEPAGE" ]] || HOMEPAGE="https://github.com/$OWNER/$REPO"
  [[ -n "$MINOS" ]] || MINOS="14.0"
  for v in ID NAME KIND; do [[ -n "${(P)v}" ]] || die "cannot determine ${(L)v} for $REPO; pass --${(L)v}"; done
  [[ "$KIND" == (windowed|hover|umbrella) ]] || die "kind must be windowed, hover or umbrella: $KIND"
  [[ "$BUNDLED" == (true|false) ]] || die "bundled must be true or false: $BUNDLED"
  PUBLISHED="${opt[published-at]:-$(now)}"

  JQ_ARGS=(--arg repo "$REPO" --arg id "$ID" --arg name "$NAME" --arg kind "$KIND"
    --arg summary "$SUMMARY" --arg version "$VERSION" --arg minOS "$MINOS" --arg url "$URL"
    --arg sha "$SHA" --argjson size "$SIZE" --arg pub "$PUBLISHED" --arg icon "$ICON"
    --arg home "$HOMEPAGE" --argjson bundled "$BUNDLED" --arg now "$(now)")
  # Umbrella first, then the bundled tools, then the optional apps; by name within each.
  JQ_PROG='
    {id: $id, repo: $repo, name: $name, kind: $kind, summary: $summary, version: $version,
     minOS: $minOS, download: $url, sha256: $sha, size: $size, publishedAt: $pub,
     icon: $icon, homepage: $home, bundled: $bundled} as $entry
    | .schemaVersion = 1
    | .updatedAt = $now
    | .apps = ([.apps[] | select(.repo != $repo)] + [$entry]
               | sort_by([(if .kind == "umbrella" then 0 elif .bundled then 1 else 2 end), (.name | ascii_downcase)]))'
  SUBJECT="Catalog: $NAME $VERSION"
fi

apply_edit() {
  local tmp="$FILE.tmp.$$"
  jq "${JQ_ARGS[@]}" "$JQ_PROG" "$FILE" > "$tmp"
  mv "$tmp" "$FILE"
}

if [[ -z "$WT" ]]; then
  apply_edit
  print -u2 "hud-catalog: ${SUBJECT#Catalog: } -> $FILE"
  exit 0
fi

# Edit, commit and push to machud main; a concurrent push is handled by redoing the edit on
# the new origin/main (the edit is a pure function of the file, so this never conflicts).
MSG="$SUBJECT"
[[ -n "${HUD_COMMIT_TRAILER-}" ]] && MSG+=$'\n\n'"$HUD_COMMIT_TRAILER"
for attempt in 1 2 3; do
  apply_edit
  git -C "$WT" add "$CATALOG_PATH"
  if git -C "$WT" diff --cached --quiet; then
    print -u2 "hud-catalog: catalog unchanged"
    exit 0
  fi
  git -C "$WT" commit -q -m "$MSG"
  if [[ -n "${HUD_CATALOG_NO_PUSH-}" ]]; then
    branch="catalog/$(date +%Y%m%d%H%M%S)"
    git -C "$WT" branch "$branch"
    print -u2 "hud-catalog: committed on $branch in $MACHUD_DIR (not pushed)"
    exit 0
  fi
  if git -C "$WT" push -q origin HEAD:main; then
    print -u2 "hud-catalog: ${SUBJECT#Catalog: }: pushed $(git -C "$WT" rev-parse --short HEAD) to machud main"
    exit 0
  fi
  git -C "$WT" fetch -q origin main
  git -C "$WT" reset -q --hard origin/main
  [[ -f "$FILE" ]] || die "$CATALOG_PATH vanished from origin/main"
done
die "push to machud main failed three times"
