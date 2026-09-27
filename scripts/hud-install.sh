#!/bin/zsh
# hud-install.sh <Product>
#
# Builds the app repo in the current directory (release, via hud-build.sh), quits a
# running copy, installs build/<Product>.app to /Applications, links its CLI onto PATH
# and launches it.
#
# Quitting: when the app's control socket answers, `<cli> quit` (a clean exit); otherwise
# a running <Product> process is asked to quit through AppleScript.
#
# Environment:
#   HUD_APPLICATIONS   install directory instead of /Applications
#   HUD_NO_LAUNCH      set to skip launching after install
#   HUD_EXTRA_LINKS    space-separated paths (relative to the repo, or absolute) of extra
#                      commands to link next to the CLI, each under its own file name,
#                      e.g. "scripts/machud"
#
# Repo hooks: when the repo has scripts/install-hooks.sh it is sourced after the build,
# before anything is quit or copied. It may set HUD_EXTRA_LINKS and define
#   hud_install_before_quit <built app>   run before the running copy is quit (e.g. to
#                                         quit a pre-rename copy of the app)
# so an app with install needs of its own extends this script instead of forking it.
set -euo pipefail

if [[ $# -lt 1 || "$1" == -h || "$1" == --help ]]; then
  print -u2 "usage: hud-install.sh <Product>"
  exit 2
fi
PRODUCT="$1"
HERE="${0:A:h}"
DEST_DIR="${HUD_APPLICATIONS:-/Applications}"

APP="$("$HERE/hud-build.sh" "$PRODUCT" release | tail -1)"
[[ -d "$APP" ]] || { print -u2 "hud-install: build did not produce an app"; exit 1; }
DEST="$DEST_DIR/$PRODUCT.app"

# The socket name is the manifest's; the CLI in Helpers carries the same name.
SOCKET_NAME="$(plutil -extract socket raw -o - "$APP/Contents/Resources/machud.json" 2>/dev/null || true)"
CLI_NAME=""
[[ -n "$SOCKET_NAME" && -x "$APP/Contents/Helpers/$SOCKET_NAME" ]] && CLI_NAME="$SOCKET_NAME"
SOCKET="$HOME/Library/Application Support/MacHUD/sockets/$SOCKET_NAME.sock"

HOOKS="$PWD/scripts/install-hooks.sh"
[[ -f "$HOOKS" ]] && source "$HOOKS"
(( $+functions[hud_install_before_quit] )) && hud_install_before_quit "$APP"

# Quit a running copy.
if [[ -n "$SOCKET_NAME" && -S "$SOCKET" ]] && print '{"command":"hello"}' | nc -U -w 2 "$SOCKET" 2>/dev/null | grep -q '"ok"'; then
  if [[ -n "$CLI_NAME" ]]; then
    "$APP/Contents/Helpers/$CLI_NAME" quit >/dev/null 2>&1 || true
  else
    print '{"command":"quit"}' | nc -U -w 2 "$SOCKET" >/dev/null 2>&1 || true
  fi
elif pgrep -x "$PRODUCT" >/dev/null; then
  osascript -e "quit app \"$PRODUCT\"" >/dev/null 2>&1 || true
fi
for _ in {1..50}; do
  pgrep -x "$PRODUCT" >/dev/null || break
  sleep 0.1
done

rm -rf "$DEST"
ditto "$APP" "$DEST"

# Link the CLI, and any HUD_EXTRA_LINKS, into the first writable directory on PATH (the
# usual user bin dirs first).
targets=()
[[ -n "$CLI_NAME" ]] && targets+=("$DEST/Contents/Helpers/$CLI_NAME")
for extra in ${=HUD_EXTRA_LINKS-}; do
  [[ "$extra" == /* ]] || extra="$PWD/$extra"
  [[ -x "$extra" ]] || { print -u2 "hud-install: HUD_EXTRA_LINKS entry is not executable: $extra"; exit 1; }
  targets+=("$extra")
done
linked=""
if (( ${#targets} )); then
  path_dirs=("${(@s/:/)PATH}")
  for dir in /opt/homebrew/bin /usr/local/bin "$HOME/bin" "$HOME/.local/bin" "${path_dirs[@]}"; do
    [[ -n "$dir" && -d "$dir" && -w "$dir" && "$dir" == /* ]] || continue
    (( ${path_dirs[(Ie)$dir]} )) || continue
    for target in "${targets[@]}"; do ln -sf "$target" "$dir/${target:t}"; done
    linked="$dir/${targets[1]:t}"
    break
  done
  [[ -n "$linked" ]] || print -u2 "hud-install: no writable directory on PATH; not linked: ${targets[*]}"
fi

[[ -n "${HUD_NO_LAUNCH-}" ]] || open "$DEST"
print "Installed $DEST${linked:+ and $linked}"
