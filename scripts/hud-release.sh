#!/bin/zsh
# hud-release.sh <Product> [version] [--dry-run] [--ref <commit>]
# hud-release.sh --check
#
# Releases the MacHUD app repo in the current directory, following docs/CONVENTIONS.md
# ("Releasing"):
#   1. version: VERSION, or the argument (written to VERSION and committed "<Product> <v>")
#   2. build: a clean copy of HEAD (a detached worktree; sibling path packages exported at the
#      branch their checkout tracks, else origin/main; HUDKit and its Kits at HUDKIT_REF) built
#      by the repo's build.sh (else hud-build.sh directly), signed with the Developer ID identity, hardened runtime, --timestamp,
#      <Product>.entitlements when present
#   3. zip: ditto -c -k --keepParent (without extended attributes, so no ._ files in the zip)
#   4. notarize: xcrun notarytool submit --wait; on rejection print the log summary and stop
#   5. staple, spctl -a -vv -t install, rezip, sha256, and check the zip unpacks to a valid app
#   6. tag v<version> (annotated), push the tag, gh release create with <Product>-<version>.zip
#      and the CHANGELOG section as notes (an existing release gets the asset replaced)
#   7. hud-catalog.sh set: the app's entry in machud/site/catalog.json, pushed to machud
#
# In HUDKit itself (no app bundle) it tags, pushes and creates the release with the CHANGELOG
# notes only, then sets the catalog's "hudkit" version.
#
# --dry-run  build, sign, zip and verify the signature; stop before notarization (no tag,
#            no release, no catalog)
# --ref R    release commit R instead of HEAD (e.g. origin/main while local commits are ahead);
#            VERSION and the CHANGELOG notes are read from R; no version argument
# --check    print what is configured (identity, credentials, gh, this repo) and exit 1 when
#            something a release needs is missing
#
# Credentials (APPLE_ID, APPLE_TEAM_ID, APPLE_APP_SPECIFIC_PASSWORD, as KEY=value lines; only
# these three keys are read, the file is never sourced) come from the first of:
#   $HUD_ENV_FILE, ./.env in the repo, ~/.config/machud/release.env
# Variables already set in the environment win. Keep the file out of git (chmod 600).
#
# Environment:
#   HUD_ENV_FILE            credentials file (above)
#   HUD_RELEASE_IDENTITY    signing identity (default: the "Developer ID Application" identity
#                           of APPLE_TEAM_ID in the keychain)
#   HUDKIT_REF              HUDKit ref to build against (default: HUDKit's newest v* tag)
#   HUD_DEP_REF             ref of the other sibling path packages (default: the upstream of the
#                           branch each checkout is on, else origin/main)
#   HUD_RELEASE_NO_CATALOG  set to skip the catalog update
#   HUD_COMMIT_TRAILER      a line appended to commit messages the script makes
#   MACHUD_DIR              the machud checkout, for the catalog (see hud-catalog.sh)
set -euo pipefail

HERE="${0:A:h}"
HUDKIT_DIR="${HERE:h}"

usage() { print -u2 "usage: hud-release.sh <Product> [version] [--dry-run] [--ref <commit>] | --check"; exit 2; }
die() { print -u2 "hud-release: $*"; exit 1; }
say() { print -u2 "==> $*"; }

CHECK=0 DRY=0 REF=""
typeset -a pos
while (( $# )); do
  case "$1" in
    --check) CHECK=1 ;;
    --dry-run) DRY=1 ;;
    --ref) (( $# >= 2 )) || usage; REF="$2"; shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) pos+=("$1") ;;
  esac
  shift
done

# --- configuration --------------------------------------------------------------------------

CRED_KEYS=(APPLE_ID APPLE_TEAM_ID APPLE_APP_SPECIFIC_PASSWORD)
CRED_FILE=""
load_creds() {
  local f
  for f in "${HUD_ENV_FILE-}" "$PWD/.env" "$HOME/.config/machud/release.env"; do
    [[ -n "$f" && -f "$f" ]] || continue
    if [[ "$f" == "$PWD/.env" ]] && ! grep -q '^\(export \)\{0,1\}APPLE_ID=' "$f"; then continue; fi
    CRED_FILE="$f"; break
  done
  [[ -n "${HUD_ENV_FILE-}" && "$CRED_FILE" != "$HUD_ENV_FILE" ]] && die "HUD_ENV_FILE not found: $HUD_ENV_FILE"
  [[ -n "$CRED_FILE" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#export }"
    key="${line%%=*}"
    (( ${CRED_KEYS[(Ie)$key]} )) || continue
    [[ -n "${(P)key-}" ]] && continue
    val="${line#*=}"
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    typeset -g "$key=$val"
  done < "$CRED_FILE"
}

find_identity() {
  if [[ -n "${HUD_RELEASE_IDENTITY-}" ]]; then print -r -- "$HUD_RELEASE_IDENTITY"; return; fi
  security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | grep "(${APPLE_TEAM_ID:-}" | head -1 \
    | sed -E 's/.*"(.*)".*/\1/'
}

notary() { # notarytool with the credentials; never echoes the password
  xcrun notarytool "$@" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD"
}

gh_slug() { # owner/repo of origin
  git remote get-url origin 2>/dev/null | sed -E 's#^(https://github.com/|git@github.com:)##; s#\.git$##'
}

load_creds

# --- --check --------------------------------------------------------------------------------

if (( CHECK )); then
  ok=1
  row() { printf '%-10s %-4s %s\n' "$1" "$2" "$3"; [[ "$2" == ok ]] || ok=0; }
  id="$(find_identity)"
  if [[ -n "$id" ]] && security find-identity -v -p codesigning | grep -qF "\"$id\""; then
    row identity ok "$id"
  else
    row identity FAIL "no Developer ID Application identity${APPLE_TEAM_ID:+ for team $APPLE_TEAM_ID} in the keychain"
  fi
  missing=()
  for k in $CRED_KEYS; do [[ -n "${(P)k-}" ]] || missing+=($k); done
  if (( ${#missing} )); then
    row creds FAIL "missing ${missing[*]} (looked in ${HUD_ENV_FILE:-.env, ~/.config/machud/release.env})"
  else
    row creds ok "${CRED_FILE:-environment}: ${CRED_KEYS[*]}"
    if notary history --output-format json >/dev/null 2>&1; then
      row notary ok "notarytool accepts the credentials"
    else
      row notary FAIL "notarytool history failed with these credentials"
    fi
  fi
  if user="$(gh api user -q .login 2>/dev/null)"; then row gh ok "logged in as $user"; else row gh FAIL "gh is not logged in (gh auth login)"; fi
  command -v jq >/dev/null && row jq ok "$(command -v jq)" || row jq FAIL "jq not found"
  hk_ref="${HUDKIT_REF:-$(git -C "$HUDKIT_DIR" tag --list 'v[0-9]*' --sort=-v:refname | head -1)}"
  if [[ -n "$hk_ref" ]]; then row hudkit ok "apps build against HUDKit $hk_ref"
  else row hudkit FAIL "no v* tag in $HUDKIT_DIR (set HUDKIT_REF)"; fi
  machud="${MACHUD_DIR:-${HUDKIT_DIR:h}/machud}"
  if git -C "$machud" cat-file -e origin/main:site/catalog.json 2>/dev/null; then
    row catalog ok "$machud: origin/main has site/catalog.json"
  else
    row catalog FAIL "no site/catalog.json on origin/main of $machud (set MACHUD_DIR)"
  fi
  if [[ -f VERSION ]] && git rev-parse --git-dir >/dev/null 2>&1; then
    v="$(tr -d ' \t\n' < VERSION)"; slug="$(gh_slug)"
    tag="absent"; git rev-parse -q --verify "refs/tags/v$v" >/dev/null && tag="present locally"
    rel="absent"; gh release view "v$v" -R "$slug" >/dev/null 2>&1 && rel="exists (re-run replaces the asset)"
    row repo ok "$slug: VERSION $v, tag v$v $tag, release $rel"
  fi
  (( ok )) && { print "ready to release"; exit 0; }
  print "not ready"; exit 1
fi

# --- release --------------------------------------------------------------------------------

(( ${#pos} >= 1 && ${#pos} <= 2 )) || usage
PRODUCT="${pos[1]}"
NEW_VERSION="${pos[2]-}"
[[ "$(git rev-parse --show-toplevel 2>/dev/null)" == "${PWD:A}" ]] || die "run from the repo root"
[[ -f VERSION ]] || die "no VERSION in $PWD"
SLUG="$(gh_slug)"; [[ -n "$SLUG" ]] || die "origin is not a GitHub remote"
REPO="${SLUG:t}"
BRANCH="$(git branch --show-current)"
IS_APP=1
[[ -f "Sources/$PRODUCT/Resources/Info.plist" ]] || IS_APP=0
[[ -f Package.swift ]] || die "no Package.swift in $PWD"

MSG_TRAILER=""
[[ -n "${HUD_COMMIT_TRAILER-}" ]] && MSG_TRAILER=$'\n\n'"$HUD_COMMIT_TRAILER"

# 1. version
BUMPED=0
[[ -n "$REF" && -n "$NEW_VERSION" ]] && die "--ref takes the version from the commit; no version argument"
if [[ -n "$NEW_VERSION" ]]; then
  [[ "$NEW_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "version must be x.y.z: $NEW_VERSION"
  if [[ "$(tr -d ' \t\n' < VERSION)" != "$NEW_VERSION" ]]; then
    (( DRY )) && die "--dry-run does not bump VERSION; run without the version or commit it first"
    git diff --quiet -- VERSION && git diff --cached --quiet -- VERSION || die "VERSION has uncommitted changes"
    print "$NEW_VERSION" > VERSION
    git commit -q -m "$PRODUCT $NEW_VERSION$MSG_TRAILER" -- VERSION
    BUMPED=1
  fi
fi
REL_SHA="$(git rev-parse --verify -q "${REF:-HEAD}^{commit}")" || die "no such commit: $REF"
at() { git show "$REL_SHA:$1" 2>/dev/null; }  # a file as of the released commit
VERSION="$(at VERSION | tr -d ' \t\n')"
[[ -n "$VERSION" ]] || die "no VERSION in ${REF:-HEAD}"
TAG="v$VERSION"
if (( ! IS_APP )); then
  src_version="$(at "Sources/$PRODUCT/$PRODUCT.swift" | sed -nE 's/.*static let version = "([^"]+)".*/\1/p' | head -1)"
  [[ -z "$src_version" || "$src_version" == "$VERSION" ]] || die "VERSION $VERSION != $PRODUCT.version $src_version"
fi
say "$PRODUCT $VERSION ($SLUG, ${REL_SHA[1,7]})"

# Release notes: the CHANGELOG section of this version.
NOTES="$(awk -v v="$VERSION" '
  index($0, "## [" v "]") == 1 { on = 1; next }
  on && /^## / { exit }
  on { print }' <(at CHANGELOG.md) | sed -e '/./,$!d')"
if [[ -z "$NOTES" ]]; then
  (( DRY )) && print -u2 "hud-release: warning: CHANGELOG.md has no [$VERSION] section" \
    || die "CHANGELOG.md has no [$VERSION] section (move Unreleased into it first)"
fi

# The tag must be absent or already at the released commit, locally and on origin.
if local_tag="$(git rev-parse -q --verify "refs/tags/$TAG^{commit}")"; then
  [[ "$local_tag" == "$REL_SHA" ]] || die "$TAG exists at ${local_tag[1,7]}, not ${REL_SHA[1,7]}"
fi
remote_tag="$(git ls-remote origin "refs/tags/$TAG^{}" | cut -f1)"
[[ -n "$remote_tag" ]] || remote_tag="$(git ls-remote origin "refs/tags/$TAG" | cut -f1)"
[[ -z "$remote_tag" || "$remote_tag" == "$REL_SHA" ]] || die "$TAG on origin is at ${remote_tag[1,7]}, not ${REL_SHA[1,7]}"

# The released commit must be on origin (the tag should point at published history).
if (( ! DRY )); then
  git fetch -q origin
  if ! git branch -r --contains "$REL_SHA" | grep -q "origin/"; then
    (( BUMPED )) || die "${REF:-HEAD} is not on origin; push $BRANCH first, or release a published commit with --ref origin/$BRANCH"
    say "Pushing the version commit to origin/$BRANCH"
    git push -q origin "HEAD:$BRANCH"
  fi
fi

publish_release() { # publish_release <asset or empty>
  local asset="$1" notes_file="$STAGE/notes.md"
  { print -r -- "$NOTES"; [[ -n "${EXTRA_NOTES-}" ]] && print -r -- $'\n'"$EXTRA_NOTES"; } > "$notes_file"
  if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    git tag -a "$TAG" "$REL_SHA" -m "$PRODUCT $VERSION$MSG_TRAILER"
  fi
  [[ -n "$remote_tag" ]] || { say "Pushing $TAG"; git push -q origin "refs/tags/$TAG"; }
  if gh release view "$TAG" -R "$SLUG" >/dev/null 2>&1; then
    say "Release $TAG exists: replacing notes${asset:+ and the asset}"
    gh release edit "$TAG" -R "$SLUG" --title "$PRODUCT $VERSION" --notes-file "$notes_file" >/dev/null
    [[ -n "$asset" ]] && gh release upload "$TAG" "$asset" -R "$SLUG" --clobber
  else
    say "Creating release $TAG"
    gh release create "$TAG" ${asset:+"$asset"} -R "$SLUG" --verify-tag \
      --title "$PRODUCT $VERSION" --notes-file "$notes_file" >/dev/null
  fi
  print -u2 "https://github.com/$SLUG/releases/tag/$TAG"
}

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/hud-release.XXXXXX")"
STAGED_WT=""
cleanup() {
  [[ -n "$STAGED_WT" ]] && git worktree remove --force "$STAGED_WT" >/dev/null 2>&1 || true
  rm -rf "$STAGE"
}
trap cleanup EXIT

# Library (HUDKit): tag and release notes only.
if (( ! IS_APP )); then
  (( DRY )) && { say "Dry run: would tag $TAG and create the release (no binary)"; exit 0; }
  publish_release ""
  [[ -z "${HUD_RELEASE_NO_CATALOG-}" && "$REPO" == hudkit ]] && "$HERE/hud-catalog.sh" hudkit "$VERSION"
  exit 0
fi

IDENTITY="$(find_identity)"
[[ -n "$IDENTITY" ]] || die "no Developer ID Application identity (run --check)"

# 2. build a clean copy of the released commit with its path dependencies next to it.
say "Staging $REPO at ${REL_SHA[1,7]} in $STAGE"
STAGED_WT="$STAGE/${PWD:t}"
git worktree add -q --detach "$STAGED_WT" "$REL_SHA"
HUDKIT_REF="${HUDKIT_REF:-$(git -C "$HUDKIT_DIR" tag --list 'v[0-9]*' --sort=-v:refname | head -1)}"
[[ -n "$HUDKIT_REF" ]] || die "HUDKit has no v* tag; set HUDKIT_REF"
typeset -A staged
BUILT_WITH=()
dep_ref() { # dep_ref <repo> <checkout>: the ref a sibling repo is built at
  local repo="$1" src="$2" upstream
  if [[ "$repo" == hudkit ]]; then print -r -- "$HUDKIT_REF"; return; fi
  if [[ -n "${HUD_DEP_REF-}" ]]; then print -r -- "$HUD_DEP_REF"; return; fi
  # The pushed state of the branch the checkout builds from (a fork's integration branch,
  # say), else origin/main.
  upstream="$(git -C "$src" rev-parse -q --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || upstream=""
  print -r -- "${upstream:-origin/main}"
}
stage_deps() { # stage_deps <package dir>: export the repo of each ../<repo>[/<sub>] path package into $STAGE
  local dir="$1" dep repo src ref
  for dep in ${(f)"$(grep -oE '\.package\(path: *"\.\./[^"]+"' "$dir/Package.swift" | sed -E 's#.*"\.\./([^"]+)"#\1#')"}; do
    repo="${dep%%/*}"
    [[ -n "$repo" && -z "${staged[$repo]-}" ]] || continue
    src="${PWD:h}/$repo"
    [[ "$repo" == hudkit ]] && src="$HUDKIT_DIR"
    [[ -d "$src" ]] || die "missing path dependency ../$repo"
    ref="$(dep_ref "$repo" "$src")"
    git -C "$src" rev-parse -q --verify "$ref^{commit}" >/dev/null || die "../$repo has no $ref"
    mkdir -p "$STAGE/$repo"
    git -C "$src" archive "$ref" | tar -x -C "$STAGE/$repo"
    staged[$repo]="$ref"
    if [[ "$ref" == v* ]]; then BUILT_WITH+=("$repo $ref")
    else BUILT_WITH+=("$repo $ref $(git -C "$src" rev-parse --short "$ref")"); fi
    stage_deps "$STAGE/$repo"
  done
}
stage_deps "$STAGED_WT"
say "Built against: ${(j:, :)BUILT_WITH}"

say "Building and signing with $IDENTITY"
# Through the repo's build.sh when it has one, so its build settings (MacHUD's HUD_HELPERS)
# apply, with this HUDKit's scripts.
if [[ -x "$STAGED_WT/build.sh" ]]; then
  APP="$(cd "$STAGED_WT" && HUD_NO_ANNOUNCE=1 HUD_SIGN_IDENTITY="$IDENTITY" HUDKIT_DIR="$HUDKIT_DIR" ./build.sh release | tail -1)"
else
  APP="$(cd "$STAGED_WT" && HUD_NO_ANNOUNCE=1 HUD_SIGN_IDENTITY="$IDENTITY" "$HERE/hud-build.sh" "$PRODUCT" release | tail -1)"
fi
[[ -d "$APP" ]] || die "build did not produce an app"
# Every helper the repo's build.sh names must be in the bundle.
for helper in ${=${"$(grep -oE 'HUD_HELPERS="[^"]*"' "$STAGED_WT/build.sh" 2>/dev/null | head -1)"#HUD_HELPERS=}//\"/}; do
  [[ -x "$APP/Contents/Helpers/$helper" ]] || die "the app has no Contents/Helpers/$helper"
done
if /usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  die "Info.plist has Sparkle keys; MacHUD apps update through the catalog (CONVENTIONS, Releasing)"
fi
codesign --verify --strict --deep "$APP" || die "codesign --verify failed"
sig="$(codesign -dv --verbose=2 "$APP" 2>&1)"
[[ "$sig" == *"flags=0x10000(runtime)"* ]] || die "hardened runtime is not on"
[[ "$sig" == *"Timestamp="* ]] || die "the signature has no secure timestamp"
for helper in "$APP"/Contents/Helpers/*(N.x); do  # executables, not the resource-bundle links
  [[ "$(codesign -dv "$helper" 2>&1)" == *"Timestamp="* ]] || die "${helper:t}: no secure timestamp"
done

OUT="$PWD/build/release"
mkdir -p "$OUT"
ZIP="$OUT/$PRODUCT-$VERSION.zip"
zipit() { rm -f "$2"; ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$1" "$2"; }

# 3. zip for notarization
zipit "$APP" "$STAGE/$PRODUCT-notarize.zip"
if (( DRY )); then
  zipit "$APP" "$ZIP"
  say "Dry run: signed and zipped, stopping before notarization"
  print "$ZIP"
  exit 0
fi

# 4. notarize
for k in $CRED_KEYS; do [[ -n "${(P)k-}" ]] || die "missing $k (run --check)"; done
say "Notarizing (xcrun notarytool submit --wait)"
result="$(notary submit "$STAGE/$PRODUCT-notarize.zip" --wait --output-format json 2>"$STAGE/notary.err")" || true
nstatus="$(jq -r '.status // empty' <<<"$result" 2>/dev/null || true)"
sub_id="$(jq -r '.id // empty' <<<"$result" 2>/dev/null || true)"
if [[ "$nstatus" != Accepted ]]; then
  print -u2 "hud-release: notarization ${nstatus:-failed} (submission ${sub_id:-none})"
  [[ -s "$STAGE/notary.err" ]] && sed 's/^/  /' "$STAGE/notary.err" >&2
  if [[ -n "$sub_id" ]]; then
    notary log "$sub_id" "$STAGE/notary-log.json" >/dev/null 2>&1 || true
    [[ -f "$STAGE/notary-log.json" ]] && jq -r '"  status: \(.status) — \(.statusSummary)",
      (.issues // [] | .[] | "  \(.severity): \(.path // "-"): \(.message)")' "$STAGE/notary-log.json" >&2
  fi
  die "not releasing $PRODUCT $VERSION"
fi
say "Notarization accepted ($sub_id)"

# 5. staple, verify, final zip
xcrun stapler staple -q "$APP"
xcrun stapler validate -q "$APP" || die "stapler validate failed"
{ spctl -a -vv -t install "$APP" 2>&1 || true; } | sed 's/^/  /' >&2
spctl -a -t install "$APP" 2>/dev/null || die "spctl rejected the app"
zipit "$APP" "$ZIP"
# The zip must unpack to a valid app with a plain unzip too (Safari, Archive Utility).
mkdir -p "$STAGE/unzip"
/usr/bin/unzip -q "$ZIP" -d "$STAGE/unzip"
[[ -z "$(find "$STAGE/unzip" -name '._*' -print -quit)" ]] || die "the zip contains AppleDouble (._) files"
codesign --verify --strict --deep "$STAGE/unzip/$PRODUCT.app" || die "the unzipped app fails codesign --verify"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
SIZE="$(stat -f%z "$ZIP")"
say "$ZIP ($SIZE bytes, sha256 $SHA)"

# 6. tag and GitHub release
EXTRA_NOTES="---
\`$PRODUCT-$VERSION.zip\`: Developer ID signed and notarized. sha256 \`$SHA\`.
Built against ${(j:, :)BUILT_WITH}."
publish_release "$ZIP"

# 7. catalog
if [[ -z "${HUD_RELEASE_NO_CATALOG-}" ]]; then
  URL="https://github.com/$SLUG/releases/download/$TAG/$PRODUCT-$VERSION.zip"
  HUD_APP_DIR="$PWD" "$HERE/hud-catalog.sh" set "$REPO" "$VERSION" "$URL" "$SHA" "$SIZE"
fi
say "Released $PRODUCT $VERSION"
