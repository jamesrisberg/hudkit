#!/bin/zsh
# hud-build.sh <Product> [release|debug]
#
# Builds a MacHUD app repo (the current directory) into build/<Product>.app, following
# docs/CONVENTIONS.md:
#   Contents/MacOS/<Product>      the <Product> executable target
#   Contents/Helpers/<cli>        the <Product>CLI target, if Sources/<Product>CLI exists;
#                                 named after the manifest's socket (= the repo name)
#   Contents/Helpers/<helper>     each executable product named in HUD_HELPERS (a process the
#                                 app runs, e.g. MacHUD's MacHUDVoice), under its product name,
#                                 with a link to each SwiftPM resource bundle in Resources (a
#                                 helper's Bundle.main is Contents/Helpers)
#   Contents/Frameworks/          every @rpath framework the app or a helper links that SwiftPM
#                                 built into the bin path (e.g. Sparkle.framework)
#   Contents/Resources/           everything in Sources/<Product>/Resources except Info.plist,
#                                 plus every *.bundle SwiftPM produced for the build (a Kit's
#                                 bundled companion or model data, e.g. BrainKit's
#                                 BrainKit_BrainKit.bundle or VoiceKit's mlx-swift_Cmlx.bundle
#                                 and Misaki_Misaki.bundle), found via `swift build --show-bin-path`
#   Contents/Info.plist           Sources/<Product>/Resources/Info.plist with
#                                 CFBundleShortVersionString from ./VERSION and
#                                 CFBundleVersion = the commit count
# then signs it with the first "Apple Development" identity, or ad-hoc when there is none:
# frameworks first, then the CLI and the helpers, then the app. <Product>.entitlements at the
# repo root is applied to the app and to every HUD_HELPERS helper (a helper the app launches
# as its child needs the same hardened-runtime exceptions, e.g. audio input).
# Finally it announces the bundle to a running MacHUD (`apps announce path=`), so the app's
# button appears in the tool dock at once. A MacHUD that is not running never fails the build.
#
# Environment:
#   HUD_SIGN_IDENTITY   signing identity to use instead of the lookup ("-" = ad-hoc). A
#                       "Developer ID Application" identity also gets a secure timestamp
#                       (--timestamp), which notarization requires; hud-release.sh sets it.
#   MACHUD_SOCKET       MacHUD socket to announce to (default: the MacHUD contract socket,
#                       ~/Library/Application Support/MacHUD/sockets/machud.sock)
#   HUD_NO_ANNOUNCE=1   skip the announcement
#   HUD_HELPERS         space-separated executable products to build and put in
#                       Contents/Helpers (e.g. HUD_HELPERS="MacHUDVoice")
#
# Prints the app path as its last line.
set -euo pipefail

if [[ $# -lt 1 || "$1" == -h || "$1" == --help ]]; then
  print -u2 "usage: hud-build.sh <Product> [release|debug]"
  exit 2
fi
PRODUCT="$1"
CONFIG="${2:-release}"
[[ "$CONFIG" == release || "$CONFIG" == debug ]] || { print -u2 "hud-build: config must be release or debug"; exit 2; }
[[ -f Package.swift ]] || { print -u2 "hud-build: run from the app repo (no Package.swift in $PWD)"; exit 1; }

RES="Sources/$PRODUCT/Resources"
PLIST="$RES/Info.plist"
[[ -f "$PLIST" ]] || { print -u2 "hud-build: missing $PLIST"; exit 1; }
VERSION_FILE="VERSION"
[[ -f "$VERSION_FILE" ]] || { print -u2 "hud-build: missing VERSION"; exit 1; }
VERSION="$(tr -d ' \t\n' < "$VERSION_FILE")"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

HAS_CLI=0
[[ -d "Sources/${PRODUCT}CLI" ]] && HAS_CLI=1
CLI_NAME=""
if (( HAS_CLI )); then
  CLI_NAME="$(plutil -extract socket raw -o - "$RES/machud.json" 2>/dev/null || true)"
  [[ -n "$CLI_NAME" ]] || { print -u2 "hud-build: $RES/machud.json has no socket (the CLI's name)"; exit 1; }
fi

HELPERS=(${=HUD_HELPERS:-})
for h in $HELPERS; do
  [[ "$h" != "$PRODUCT" && "$h" != "$CLI_NAME" ]] \
    || { print -u2 "hud-build: helper $h collides with the app or its CLI"; exit 1; }
done

swift build -c "$CONFIG" --product "$PRODUCT"
if (( HAS_CLI )); then swift build -c "$CONFIG" --product "${PRODUCT}CLI"; fi
for h in $HELPERS; do swift build -c "$CONFIG" --product "$h"; done
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/$PRODUCT.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/$PRODUCT" "$APP/Contents/MacOS/$PRODUCT"
# Resources: the MacHUD manifest, the settings schema, the icon, anything else the app reads.
for f in "$RES"/*(N); do
  [[ "${f:t}" == Info.plist ]] && continue
  cp -R "$f" "$APP/Contents/Resources/"
done
# SwiftPM resource bundles (a Kit's bundled companion or model data — BrainKit's
# BrainKit_BrainKit.bundle, VoiceKit's mlx-swift_Cmlx.bundle and Misaki_Misaki.bundle) land
# beside the build products, one per bundling target; `swift build` does not put them in the
# app, so an app using them ships broken unless they are copied in here, before signing, so
# codesign seals them into the app's signature. -p keeps their executable bits (a companion's
# test fixtures and node scripts).
for b in "$BIN"/*.bundle(N); do
  cp -Rp "$b" "$APP/Contents/Resources/"
done
cp "$PLIST" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$APP/Contents/Info.plist"
if [[ -f "$RES/AppIcon.icns" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi
# The CLI lives in Helpers: Contents/MacOS/<cli> would collide with <Product> on a
# case-insensitive volume (sift vs Sift).
if (( HAS_CLI )); then
  mkdir -p "$APP/Contents/Helpers"
  cp "$BIN/${PRODUCT}CLI" "$APP/Contents/Helpers/$CLI_NAME"
fi
if (( ${#HELPERS} )); then
  mkdir -p "$APP/Contents/Helpers"
  for h in $HELPERS; do cp "$BIN/$h" "$APP/Contents/Helpers/$h"; done
  # A helper's Bundle.main is Contents/Helpers, not the app, so SwiftPM's resource accessor
  # (Bundle.module) looks for its bundles there and stops the process when they are missing.
  # Relative links into Contents/Resources keep one copy, sealed by the app's signature.
  for b in "$BIN"/*.bundle(N); do ln -s "../Resources/${b:t}" "$APP/Contents/Helpers/${b:t}"; done
fi
# Frameworks SwiftPM links by @rpath (a binary target such as Sparkle) sit beside the products
# and are not in the app unless copied; the executables find them through
# @executable_path/../Frameworks. Absolute install names (a Homebrew dylib) are left as they are.
EXECUTABLES=("$APP/Contents/MacOS/$PRODUCT")
# Plain files only: the resource bundle links beside a helper are not executables.
for f in "$APP/Contents/Helpers"/*(N.); do EXECUTABLES+=("$f"); done
FRAMEWORKS=()
for exe in $EXECUTABLES; do
  for fw in ${(f)"$(otool -L "$exe" | sed -nE 's|^[[:space:]]*@rpath/([^/]+\.framework)/.*|\1|p')"}; do
    [[ -n "$fw" && -d "$BIN/$fw" && ${FRAMEWORKS[(Ie)$fw]} -eq 0 ]] && FRAMEWORKS+=("$fw")
  done
done
if (( ${#FRAMEWORKS} )); then
  mkdir -p "$APP/Contents/Frameworks"
  for fw in $FRAMEWORKS; do cp -Rp "$BIN/$fw" "$APP/Contents/Frameworks/"; done
fi

IDENTITY="${HUD_SIGN_IDENTITY-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Apple Development' | sed -E 's/.*"(.*)".*/\1/' || true)"
fi
[[ -n "$IDENTITY" ]] || IDENTITY="-"
SIGN=(codesign --force --sign "$IDENTITY")
[[ "$IDENTITY" != "-" ]] && SIGN+=(--options runtime)
[[ "$IDENTITY" == "Developer ID Application"* ]] && SIGN+=(--timestamp)
# Extended attributes (Finder info, quarantine, resource forks copied in with a resource)
# make codesign refuse the bundle, and would travel into a release zip.
xattr -cr "$APP"
ENTITLEMENTS=()
[[ -f "$PRODUCT.entitlements" ]] && ENTITLEMENTS=(--entitlements "$PRODUCT.entitlements")
# Inside out: codesign seals what is already signed, so the app goes last.
for fw in $FRAMEWORKS; do "${SIGN[@]}" "$APP/Contents/Frameworks/$fw"; done
if (( HAS_CLI )); then
  "${SIGN[@]}" "$APP/Contents/Helpers/$CLI_NAME"
fi
for h in $HELPERS; do "${SIGN[@]}" "${ENTITLEMENTS[@]}" "$APP/Contents/Helpers/$h"; done
"${SIGN[@]}" "${ENTITLEMENTS[@]}" "$APP"
if [[ "$IDENTITY" == "-" ]]; then
  print -u2 "Signed ad-hoc (permission grants such as Accessibility may need renewing after each rebuild)"
else
  print -u2 "Signed with: $IDENTITY"
fi
print -u2 "Built $PRODUCT $VERSION ($BUILD_NUMBER), $CONFIG"

# Tell a running MacHUD about the bundle so its dock shows the app now, not after a relaunch.
announce() {
  local sock="${MACHUD_SOCKET:-$HOME/Library/Application Support/MacHUD/sockets/machud.sock}"
  local bundle="$PWD/$APP" reply
  bundle="${bundle//\\/\\\\}"; bundle="${bundle//\"/\\\"}"
  if [[ ! -S "$sock" ]]; then print -u2 "MacHUD not running"; return 0; fi
  reply="$(print -r -- "{\"command\":\"apps\",\"args\":{\"action\":\"announce\",\"path\":\"$bundle\"}}" \
    | nc -U -w 5 "$sock" 2>/dev/null)" || true
  if [[ "$reply" == *'"ok":true'* ]]; then
    print -u2 "Announced to MacHUD"
  elif [[ -z "$reply" ]]; then
    print -u2 "MacHUD not running"
  else
    print -u2 "MacHUD did not take the announcement: $reply"
  fi
}
[[ "${HUD_NO_ANNOUNCE:-}" == 1 ]] || announce || true
print "$PWD/$APP"
