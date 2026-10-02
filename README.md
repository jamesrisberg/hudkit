# HUDKit

The shared contract, visual language and build tooling for MacHUD-aware macOS apps (Sift, Stash,
Scratch, MechaHUD, ffmpegHUD, magickHUD, serversHUD and MacHUD itself).
macOS 14+, Swift 5.9+.

## What it is

A Swift package every MacHUD app links, plus the scripts and template that make each app repo
look the same:

- `Sources/HUDKit`: the control socket, manifest, contract router, dock geometry, settings
  schema, glass chrome, motion and hotkeys.
- `Kits/BrainKit`: a separate Swift package, the local agent brain (Codex, Claude Code or
  Hermes behind a bundled Node companion) with its launcher, client and transcript model;
  see [its README](Kits/BrainKit/README.md).
- `Kits/VoiceKit`: a separate package for voice (wake word, trigger phrases, reply voices and
  voice settings); an app that depends only on HUDKit never fetches it. See
  [its README](Kits/VoiceKit/README.md).
- `scripts/`: `hud-build.sh`, `hud-install.sh`, `hud-new-app.sh` and the `hud-ci.yml` workflow.
- `Templates/App`: a minimal complete app that `hud-new-app.sh` instantiates.
- [docs/](docs/README.md): the [contract spec](docs/CONTRACT.md), the
  [agent guide](docs/AGENT-GUIDE.md) for building an app, the [CLI reference](docs/CLI.md) and
  the repo [conventions](docs/CONVENTIONS.md) every app follows.

**Building a MacHUD app?** Start with [docs/AGENT-GUIDE.md](docs/AGENT-GUIDE.md) (humans and AI
agents alike; [llms.txt](llms.txt) lists the docs in reading order, and Claude Code picks up the
[`hudkit-app` skill](.claude/skills/hudkit-app/SKILL.md) in this repo). To use the skill from any
directory, link it: `ln -s ~/dev/hudkit/.claude/skills/hudkit-app ~/.claude/skills/hudkit-app`.

## Install

Check HUDKit out next to the apps (`~/dev/hudkit` beside `~/dev/sift`) and depend on it by path:

```swift
.package(path: "../hudkit")   // sibling checkout
.product(name: "HUDKit", package: "hudkit")
```

## Use

### What an app gets

| Area | Types |
|---|---|
| Socket | `HUDSocket.path(for:)`, `HUDSocketServer`, `HUDSocketClient`, `HUDSubscription` |
| Manifest | `HUDManifest`, `HUDManifest.Panel`, `HUDSize`, `HUDManifestScanner` |
| Contract | `HUDPanelHost`, `HUDControlRouter`, `HUDPanelState`, `HUDPanelMode`, `HUDControlError`, `HUDPanelTransition`, `HUDDrop` |
| Dock | `HUDDockPosition`, `HUDDockLayout`, `HUDDockAxis`, `HUDDockAlignment`, `HUDDockRegistry`, `HUDDockStyle`, `HUDDockPlacement`, `HUDDockStripView` / `HUDDockStrip`, `HUDDockTile`, `HUDDockItem` |
| Chrome | `HUDGlassView`, `HUDGlass` / `.hudGlass()`, `HUDGlossView`, `HUDPanelWindow` |
| Motion | `HUDSpring`, `HUDAnimation`, `HUDParking`, `HUDEdge` |
| Notch | `HUDNotchGeometry`, `HUDFullscreenObserver`, `HUDScreenSnapshot`, `HUDWindowSnapshot` |
| Hotkeys | `HUDHotKey`, `HUDHotKeyCenter` |
| Menu bar | `HUDStatusIcon`, `HUDMenuBridge`, `HUDStatusItemPolicy`, `HUDMenuHost` |

### The contract in ten lines

```swift
import HUDKit

@MainActor final class App: NSObject, NSApplicationDelegate, HUDPanelHost {
    let server = HUDSocketServer(path: HUDSocket.path(for: "myapp"))
    lazy var router = HUDControlRouter(host: self, server: server)
    var shown = false
    var panelStates: [HUDPanelState] { [HUDPanelState(id: "main", visible: shown)] }
    func showPanel(_ id: String) throws { shown = true; window.orderFrontRegardless() }
    func hidePanel(_ id: String) throws { shown = false; window.orderOut(nil) }
    func applicationDidFinishLaunching(_ n: Notification) { router.install(); server.start() }
}
```

Ship `Contents/Resources/machud.json` describing the panels:

```json
{"id": "com.example.myapp", "name": "MyApp", "socket": "myapp",
 "panels": [{"id": "main", "title": "Main", "symbol": "star", "defaultSize": [320, 240]}]}
```

### Chrome

`HUDGlassView` uses `NSGlassEffectView` (Liquid Glass) on macOS 26 and an `NSVisualEffectView`
(`.hudWindow`) elsewhere, or whenever a `maskImage` is set. Styles: `.panel`, `.strip`, `.plain`,
or your own `Style(cornerRadius:borderWidth:borderAlpha:gloss:material:)`. Add content with
`addSubview`. In SwiftUI: `content.hudGlass(.strip)`.

`HUDPanelWindow(contentRect:keyable:level:)` is the borderless, non-activating, floating,
all-Spaces hover panel; `HUDPanelWindow(contentRect:behavior: .windowed)` is the same glass as a
normal window (normal level, activates its app, current Space, Dock tile while shown via
`HUDDockPolicy`). `applyHUDRecipe(behavior:)` applies or switches either recipe, and
`activateOnShow(_:)` brings the window forward for a `panel show` without stealing focus on
`reason=hover`. `HUDPanelWindow(contentRect:behavior: .widget)` is a desktop widget window
(desktop layer or floating, every Space, never focused, locked); `HUDWidgetHost` makes them.
`HUDAnimation.reveal/conceal` use the 0.22 s ease-out / 0.18 s ease-in timings;
`HUDParking.offScreenFrame(for:edge:peek:)`, `restFrame(for:in:)`, `slideOut`/`slideIn` park a
window against a screen edge with a visible sliver.

### Notch anchor

`HUDNotchGeometry` is pure frame math (no `NSScreen` needed, so it is unit-testable): given a
screen's `frame`, `visibleFrame`, `safeAreaInsetTop` and `notchWidth`, `notchRect` gives the
camera housing's rect (nil without one) and `anchorFrame(for:)` gives the frame for a panel of a
given size, centered under the notch — or, on a screen without one (or behind a full-screen app,
which hides the menu bar and grows `visibleFrame` to the screen edge), hanging from the menu bar
instead. `HUDNotchGeometry(screen:)` reads the live values.

`HUDPanelWindow.anchorUnderNotch(size:on:)` moves a panel to that frame and raises it to
`HUDPanelWindow.notchAnchorLevel` (`.statusBar`) so it draws above the menu bar layer
(`.mainMenu`); call it again after a resize or a screen change.

`HUDFullscreenObserver` publishes, per screen, whether the frontmost app is full screen there
(`isFullScreen(screenID:)`, `onChange`), so a host can hide or fall back a notch-anchored panel
while a full-screen app owns that part of the screen. A screen counts as full screen only on
positive window evidence — a layer-0 window owned by the frontmost app whose bounds equal the
screen's full frame (`HUDWindowSnapshot`, read from `CGWindowListCopyWindowInfo`, no Screen
Recording permission needed) — not from `visibleFrame` alone, which an auto-hidden menu bar and
Dock can also fill with no full-screen app running. It re-evaluates on `NSWorkspace`
app-activation and active-Space-change notifications; `screensProvider`, `windowsProvider` and
`frontmostApplicationPID` are the injected sources for tests, defaulting to `NSScreen.screens`,
the live window list and `NSWorkspace`.

## MacHUD contract

The full spec, with every verb's request, reply and errors, the behaviour MacHUD expects and a
compliance checklist, is [docs/CONTRACT.md](docs/CONTRACT.md). In short:

### Wire format

Unix socket at `~/Library/Application Support/MacHUD/sockets/<socket>.sock` (dir 0700, socket
0600). One JSON object per line: request `{"command": "...", "args": {...}}`, response
`{"ok": true, ...}` or `{"ok": false, "error": "..."}`. One request per connection, except
`subscribe` (optionally `events=a,b`), which is acknowledged with `{"ok":true,"subscribed":true}`
and then receives `{"event": "...", ...}` lines until either side closes.

Required verbs (served by `HUDControlRouter`): `hello`, `panel show|hide|toggle|frame|mode id=`,
`state`, `subscribe`, `settings get|set|schema`, `action name=`, `quit`. `help` is built into the server.
`panel mode id= parked` may carry `edge=` and `peek=`: MacHUD passes the loadout slot's edge so the
app parks there (implement `setPanelMode(_:mode:options:)`; the default ignores them).
`hello` answers `{hudkit, app, name, version, panels, verbs}`: `hudkit` is the contract version
(`HUDKit.version`), `version` the app's own (`CFBundleShortVersionString`, from its `VERSION` file).
The router publishes a `state` event after every `panel` command; the app publishes the rest
(hotkeys, menus, actions) with `router.publishState()`.

Optional verbs: `menu` (the app's status menu as `{items:[{id, title, kind, enabled, state,
keyEquivalent?, modifiers?, items?}]}`) and `menu-invoke id= [title=]`, served once the app sets
`router.menuProvider`; see "Menu bar consolidation" in [docs/CONVENTIONS.md](docs/CONVENTIONS.md).
`widget create|update|remove|list|sync|edit|reveal|schema`, served once the app sets
`router.widgetHost`; see below.

### Widgets

Any app may serve desktop widgets next to its panels: one `kind: widget` manifest panel per
widget type (with a `widget` object: `sizes` small 1×1 / medium 2×1 / large 2×2 / extraLarge 4×2
grid cells, `defaultSize`, `multiple`, `refresh`, a per-instance `settingsSchema`) and one view
registered on a `HUDWidgetHost`:

```swift
let widgets = HUDWidgetHost()
widgets.register("clock") { ClockWidget(context: $0) }   // context: instance, size, settings, isEditing
control.router.widgetHost = widgets                      // before the socket starts
```

MacHUD owns the instances (id, type, size, frame, layer, settings) and drives them with the
`widget` verb, including `sync` after every (re)connect; the user's edits come back as `widget`
events (`frame`, `size`, `remove`, `configure`, `settings`, `open`). `writeSnapshot(type:size:to:)`
renders a type to PNG. Widget panels never get a dock button (`HUDManifest.dockPanels`), and a kind
HUDKit does not know is kept and ignored rather than read as windowed. Spec:
[docs/CONTRACT.md § Widgets](docs/CONTRACT.md#widgets).

### The MacHUD dock

MacHUD shows one Dock-like strip of app buttons (hover panels first, then windowed; within a
kind by the manifest's `order`, see `HUDManifest.dockSorted`). The contract's dock parts:

| Where | What |
|---|---|
| `panel show\|toggle` | optional `from=<edge>`, `anchor=x,y,w,h` (dock button frame, AppKit coords), `reason=hover\|click\|summon` → `showPanel(_:options:)` / `togglePanel(_:options:)` |
| `panel hide` | optional `to=<edge>` (plus `anchor`, `reason`) → `hidePanel(_:options:)` |
| `action drop` | `paths=<p1\|p2>`, each path percent-encoded (`HUDDrop.encode/decode`), optional `id=<panel>`; sent only to panels with the `acceptsFileDrop` capability |
| manifest | `iconName` (SF Symbol when the app icon is missing), `panels[].order` (Int) |
| `docks.json` | `~/Library/Application Support/MacHUD/docks.json`: `{"<app id>": {"position", "frames": [[x,y,w,h]], "updatedAt", "pid"}}` via `HUDDockRegistry` |

The options variants default to the plain `showPanel`/`hidePanel`, so a host may implement only those;
`from`/`to`/`anchor` are validated by the router, other keys pass through. Sliding out of the dock
takes two lines:

```swift
func showPanel(_ id: String, options: [String: String]) throws {
    let t = HUDPanelTransition(options)
    HUDAnimation.slide(in: window, from: t.from ?? .top, to: t.panelFrame(size: window.frame.size) ?? window.frame)
}
func hidePanel(_ id: String, options: [String: String]) throws {
    HUDAnimation.slideOut(window, toward: HUDPanelTransition(options).to ?? .top)
}
```

Strips snap to eight `HUDDockPosition`s: the middle of each edge (one row/column) and each corner
(an L; `HUDDockLayout.lShape` gives both arms sharing the corner square).
`HUDDockPosition.nearest(to:in:)` picks by sector (the outer 25% of an edge is its corner).
Sibling strips publish their frames with `HUDDockRegistry.publish(appID:position:frames:)`,
`watch` the file, and place themselves with `HUDDockLayout.avoiding(frame:others:along:in:)`.
A strip's chrome is `HUDDockStripView` (SwiftUI: `HUDDockStrip`), the MacHUD tool dock's own
view: `HUDDockStyle.standard` holds its measurements (44 pt icons, 64 pt thick, 18 pt corners)
and `HUDDockStyle.placement(groups:position:insets:in:)` lays out an edge run or an L. The view
reports clicks, menus, file drops and where a background drag snaps to through
`HUDDockStripDelegate`, and `writeSnapshot(to:)` draws it without Screen Recording.

## Settings

`HUDSettingsSchema` is the format MacHUD's shared settings window renders: a manifest panel's
`settingsSchema` names a JSON file in `Contents/Resources`, and `settings schema` serves it.

```json
{"version": 1, "settings": [
  {"key": "collisionPolicy", "title": "When names collide", "type": "enum", "group": "Files",
   "options": [{"value": "keepBoth", "title": "Keep both"}, "skip"], "default": "keepBoth"},
  {"key": "showHidden", "title": "Show hidden files", "type": "bool", "default": false}]}
```

Types: `string`, `bool`, `int`, `number` (a decimal), `enum`, `path` (unknown types read as
`string`); `int` and `number` take `min`, `max` and `step`. Values travel as strings over
`settings set`; `schema.validate(values)` checks them all before an app applies any, and the
router checks the values its host's schema describes before calling `updateSettings`.

```sh
echo '{"command":"hello"}' | nc -U ~/Library/Application\ Support/MacHUD/sockets/myapp.sock
```

## Build from source

```sh
swift test                  # HUDKitTests
```

Each kit in `Kits/` is its own package and is tested from its folder:

```sh
cd Kits/BrainKit && swift test                                        # BrainKitTests
cd Kits/BrainKit/Sources/BrainKit/Companion && node --test test/*.test.mjs   # its Node companion
```

CI runs the same on `macos-26` ([.github/workflows/ci.yml](.github/workflows/ci.yml)). The
version is in [VERSION](VERSION) and `HUDKit.version` (kept equal); changes are in
[CHANGELOG.md](CHANGELOG.md).

### App scripts and template

```sh
scripts/hud-new-app.sh widgethud widgetHUD    # new app repo next to HUDKit, from Templates/App
cd ../widgethud && swift test && ./build.sh   # build.sh/install.sh are shims into scripts/
```

See [docs/CONVENTIONS.md](docs/CONVENTIONS.md) for the layout, the shims and what each script does,
and [docs/AGENT-GUIDE.md](docs/AGENT-GUIDE.md) for building the app out and verifying it.

## Isolation env vars for testing

Each app reads `<REPO>_HOME`, `<REPO>_SOCKET` and `<REPO>_NO_HOTKEYS` (see the conventions).
HUDKit itself reads `HUD_NO_ANNOUNCE=1` (no launch announcement to MacHUD; `hud-build.sh` honours
it too), `MACHUD_SOCKET` (where announcements go) and `MACHUD_HOST_FILE` (the `host.json` that
`HUDStatusItemPolicy` follows, for isolated MacHUD instances). A test instance sets the three app
variables and `HUD_NO_ANNOUNCE=1`; [docs/AGENT-GUIDE.md](docs/AGENT-GUIDE.md#7-isolation-never-disturb-the-user)
has the full recipe. HUDKit's tests use temporary socket paths and never touch the real sockets
directory.

## License

MIT, see [LICENSE](LICENSE). `Kits/VoiceKit/Vendor/Kokoro` is Apache-2.0, see its
[LICENSE](Kits/VoiceKit/Vendor/Kokoro/LICENSE) and
[PROVENANCE.md](Kits/VoiceKit/Vendor/Kokoro/PROVENANCE.md).
