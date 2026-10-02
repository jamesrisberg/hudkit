---
name: hudkit-app
description: Build, change or check a MacHUD app (a macOS menu bar HUD app on HUDKit that MacHUD shows in its tool dock, like Scratch, Sift or Stash). Use when asked to make a new MacHUD/HUD app, add a panel, desktop widget, action, setting, CLI command or file drop to one, make an app MacHUD-compliant, or debug its control socket. Covers scaffolding with hud-new-app.sh, the manifest, HUDPanelHost, hover vs windowed windows, widgets, --snapshot visual checks, isolated testing and the compliance checklist.
---

# Building MacHUD apps with HUDKit

HUDKit is at `~/dev/hudkit`; apps are sibling repos (`~/dev/<repo>`) that depend on it at
`../hudkit`. Read these, in this order, before writing code:

1. `~/dev/hudkit/docs/AGENT-GUIDE.md`: the step-by-step playbook with a complete worked example
   (TallyHUD). Follow it literally.
2. `~/dev/hudkit/docs/CONTRACT.md`: the spec: manifest, socket, verbs, events, behaviour, what
   MacHUD guarantees, the compliance checklist.
3. `~/dev/hudkit/docs/CLI.md`: the `<repo>` CLI grammar and `machud`.
4. `~/dev/hudkit/docs/CONVENTIONS.md`: repo layout, names, versions, commits.

## Playbook (condensed)

1. **Decide** repo (lowercase, e.g. `tallyhud`), Product (`TallyHUD`), panel kind (`hover`: a
   glance panel that drops out of the dock on hover; `windowed`: a working window; `widget`: a
   tile MacHUD places on the desktop, served next to the other kinds or on its own), actions,
   settings, file drops, an unused hotkey (AGENT-GUIDE section 0). Ask the user if unclear.
2. **Scaffold**: `~/dev/hudkit/scripts/hud-new-app.sh <repo> <Product>`, then
   `cd ~/dev/<repo> && swift test && ./build.sh debug`. The generated app is already compliant.
3. **Logic in the Kit** (`Sources/<Product>Kit`, Foundation only) with XCTest tests.
4. **Manifest** `Sources/<Product>/Resources/machud.json` and `ControlHost.builtinManifest`
   stay identical; keep `"frame"` in `verbs`; `kind` matches the window behaviour.
5. **Host** `ControlHost: HUDPanelHost`: actions in `performAction` (call `done` exactly once,
   return fast, slow work off the main thread), `router.publishState()` on every change that
   does not come through `panel`, errors as `HUDControlError`. `acceptsFileDrop` requires an
   `action drop` handler (`HUDDrop.urls(from:)`).
6. **UI**: SwiftUI in `PanelView` on `HUDGlassView`; hover → `HUDPanelWindow(contentRect:)`,
   windowed → `HUDPanelWindow(contentRect:behavior: .windowed)` + `activateOnShow(transition)`.
   Never take focus on `reason=hover`. The template already installs `HUDEditMenu` and wires
   menu bar consolidation (`router.menuProvider` + `HUDStatusItemPolicy.attach(..., store: .home(...))`).
7. **Settings**: `AppSettings` (each field in `init(from:)` via `Self.value`), `AppSettings.keys`,
   `settings.json` (types `string bool int number enum path`; `min`/`max`/`step` on numbers).
8. **CLI** shorthands in `Sources/<Product>CLI/main.swift`, then `HUDSocketClient.runCLI`.
9. **Widgets** (any app may serve them; AGENT-GUIDE "Widgets", CONTRACT § Widgets). One
   manifest panel per widget type, in `machud.json` and `builtinManifest` alike:
   `{"id": "count", "kind": "widget", "widget": {"sizes": ["small", "medium"], "defaultSize":
   "small", "multiple": true, "settingsSchema": "count.widget.json"}}`. The per-instance
   settings schema is its own file, `Resources/<type>.widget.json` (same format as
   `settings.json`, kept apart from the app's settings). In the app delegate, before the socket
   starts: `let widgets = HUDWidgetHost(manifest:)`, `widgets.register("count") { CountWidget(context: $0) }`
   (a SwiftUI view over a `HUDWidgetContext`; `context.configure()` for a "Set a place" button,
   `openApp()`, `updateSettings`), `widgets.onOpen`, `control.router.widgetHost = widgets`. HUDKit
   owns the glass windows (desktop layer or floating, every Space, never focused, locked outside
   MacHUD's edit mode); MacHUD owns the instances and re-sends them with `widget sync` on every
   connect. A widget-only app has no dock panel: `panelStates` is empty and the compliance
   checklist runs with `PANEL=` (empty). Needs MacHUD on HUDKit 0.3+.
   Check with a `--snapshot-widgets <dir>` launch flag: render each type at each size from
   sample data with `widgets.writeSnapshot(type:size:to:)` (and the empty, no-access and error
   states), print the paths and quit, without starting the socket, announcing, or reading
   tokens or other secrets; then look at the PNGs.
10. **Docs**: the app's `docs/CONTRACT.md`, README tables, `CHANGELOG.md`.

## Verify (always, with isolation)

Never touch the user's running apps: set `<REPO>_HOME`, `<REPO>_SOCKET`, `<REPO>_NO_HOTKEYS` and
`HUD_NO_ANNOUNCE=1` on every launch (and `HUD_NO_ANNOUNCE=1` on `./build.sh`, which otherwise
adds the build to the user's MacHUD dock), quit with `quit` (never `pkill`), never launch
MacHUD's binary without `MACHUD_SOCKET`/`MACHUD_CONFIG`/`MACHUD_NO_HOTKEYS`, never `./install.sh`
or edit `~/.config/machud/layouts.json` without asking.

```sh
cd ~/dev/<repo>
export <REPO>_HOME=/tmp/<repo>-test <REPO>_SOCKET=<repo>-test <REPO>_NO_HOTKEYS=1 HUD_NO_ANNOUNCE=1
swift test > /tmp/<repo>-swifttest.txt 2>&1; echo "exit $?"      # 0
./build.sh debug
build/<Product>.app/Contents/MacOS/<Product> --snapshot /tmp/<repo>.png   # then look at the PNG
# widgets: build/<Product>.app/Contents/MacOS/<Product> --snapshot-widgets /tmp/<repo>-widgets
# a snapshot never serves the socket, announces or reads tokens: it returns before that setup
build/<Product>.app/Contents/MacOS/<Product> > /tmp/<repo>-test.log 2>&1 &
CLI=build/<Product>.app/Contents/Helpers/<repo>
for i in {1..50}; do $CLI hello > /dev/null 2>&1 && break; sleep 0.2; done
$CLI hello; $CLI panel show id=<panel>; $CLI state; $CLI panel hide id=<panel>
# paste CONTRACT.md's compliance checklist (all its blocks; the last ends with quit)
# with SOCK="$HOME/Library/Application Support/MacHUD/sockets/<repo>-test.sock" PANEL=<panel>
# (PANEL= for a widget-only app) and TYPE=<widget type> for the widget block
unset <REPO>_HOME <REPO>_SOCKET <REPO>_NO_HOTKEYS HUD_NO_ANNOUNCE
```

(`<REPO>` is the repo name in upper case: `TALLYHUD_HOME`.) Registering with MacHUD
(`./install.sh`, an announced dev build, or an isolated MacHUD) is AGENT-GUIDE section 9.

## Done when

`swift test` passes; the snapshot looks right; every compliance check prints PASS; manifest,
`builtinManifest`, `settings.json` and the app's docs agree (every widget type has a registered
view and a snapshot you looked at); commits are atomic on `main`, authored by the user only (no
`Co-Authored-By` or other agent trailer) and **not pushed** unless the user says so. Full list:
AGENT-GUIDE section 11.
