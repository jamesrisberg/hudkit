---
name: hudkit-app
description: Build, change or check a MacHUD app (a macOS menu bar HUD app on HUDKit that MacHUD shows in its tool dock, like Scratch, Sift or Stash). Use when asked to make a new MacHUD/HUD app, add a panel, action, setting, CLI command or file drop to one, make an app MacHUD-compliant, or debug its control socket. Covers scaffolding with hud-new-app.sh, the manifest, HUDPanelHost, hover vs windowed windows, --snapshot visual checks, isolated testing and the compliance checklist.
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
   glance panel that drops out of the dock on hover; `windowed`: a working window), actions,
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
9. **Docs**: the app's `docs/CONTRACT.md`, README tables, `CHANGELOG.md`.

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
build/<Product>.app/Contents/MacOS/<Product> > /tmp/<repo>-test.log 2>&1 &
CLI=build/<Product>.app/Contents/Helpers/<repo>
for i in {1..50}; do $CLI hello > /dev/null 2>&1 && break; sleep 0.2; done
$CLI hello; $CLI panel show id=<panel>; $CLI state; $CLI panel hide id=<panel>
# paste CONTRACT.md's compliance checklist (both blocks; the second ends with quit)
# with SOCK="$HOME/Library/Application Support/MacHUD/sockets/<repo>-test.sock" PANEL=<panel>
unset <REPO>_HOME <REPO>_SOCKET <REPO>_NO_HOTKEYS HUD_NO_ANNOUNCE
```

(`<REPO>` is the repo name in upper case: `TALLYHUD_HOME`.) Registering with MacHUD
(`./install.sh`, an announced dev build, or an isolated MacHUD) is AGENT-GUIDE section 9.

## Done when

`swift test` passes; the snapshot looks right; every compliance check prints PASS; manifest,
`builtinManifest`, `settings.json` and the app's docs agree; commits are atomic on `main` with
the agent trailer and **not pushed** unless the user says so. Full list: AGENT-GUIDE section 11.
