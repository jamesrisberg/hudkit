# The MacHUD app contract

**Contract version 0.1** (HUDKit 0.1.0, `HUDKit.version`). This is the canonical spec of what a
MacHUD app ships and serves, and what MacHUD does with it. Every statement here was checked
against HUDKit's code (`Sources/HUDKit`) and MacHUD's (`~/dev/machud/Sources/MacHUDCore`); when
another document disagrees, this one and the code win.

- **App**: a menu bar macOS app (Scratch, Sift, Stash, ...) built on HUDKit. It ships a manifest
  and serves a control socket.
- **MacHUD**: the umbrella app. It discovers apps by their manifest, supervises them, shows them
  in its tool dock and drives them over their sockets.
- **HUDKit**: the Swift package that implements the app side (`HUDSocketServer`,
  `HUDControlRouter`, `HUDPanelHost`); an app built from `Templates/App` is compliant as
  generated.

Keywords: **must** is required for MacHUD to work with the app; **should** is expected of a
family app; **may** is optional.

Contents: [Versioning](#versioning) · [Manifest](#manifest) · [Socket](#socket) ·
[Verbs](#verbs) · [subscribe](#subscribe-and-state-events) · [Settings schema](#settings-schema) ·
[docks.json](#docksjson) · [Behaviour](#behaviour-hover-and-windowed) · [File drops](#file-drops) ·
[Agent sessions](#agent-sessions) · [Text feed](#text-feed) ·
[Launch announcement](#launch-announcement) · [Menu bar consolidation](#menu-bar-consolidation) ·
[What MacHUD guarantees](#what-machud-guarantees) · [Compliance checklist](#compliance-checklist)

## Versioning

`hello` reports `hudkit`, the contract version the app was built against (`HUDKit.version`),
and `version`, the app's own (`CFBundleShortVersionString`, which `hud-build.sh` fills from the
repo's `VERSION`). MacHUD gates contract features on `hudkit`, never on `version`. While HUDKit is
0.x, a contract addition bumps the minor version and additive API or fixes bump the patch.

Contract 0.1 is everything this document describes. What an app may leave out is marked
**may** or optional where it appears (the `menu`/`menu-invoke` verbs, file drops, `mode` and
`frame`); `showPanel(_:options:)` and `hidePanel(_:options:)` default to `showPanel(_:)` and
`hidePanel(_:)`, so an app that ignores the dock's transition options needs no code for them.

## Manifest

`<App>.app/Contents/Resources/machud.json`, UTF-8 JSON. MacHUD reads it **without launching the
app**. In an app repo it lives at `Sources/<Product>/Resources/machud.json`; `hud-build.sh`
copies it into the bundle.

```json
{
  "id": "xyz.machud.tallyhud",
  "name": "TallyHUD",
  "socket": "tallyhud",
  "iconName": "number.circle",
  "panels": [
    {
      "id": "main",
      "title": "TallyHUD",
      "symbol": "number.circle",
      "kind": "hover",
      "order": 90,
      "defaultSize": [320, 160],
      "capabilities": ["acceptsFileDrop"],
      "verbs": ["show", "hide", "toggle", "frame", "mode", "say", "bump", "reset", "drop"],
      "settingsSchema": "settings.json"
    }
  ]
}
```

### Top level

| Key | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `id` | string | yes | | The app's bundle identifier (`CFBundleIdentifier`). MacHUD's key for the app everywhere (`apps`, loadouts, `docks.json`). Family apps use `xyz.machud.<repo>`. |
| `name` | string | yes | | Display name (dock label, menus, settings tab). |
| `socket` | string | yes | | Socket **name**: the path is `~/Library/Application Support/MacHUD/sockets/<socket>.sock`. A value starting with `/` is used as an absolute path. Family apps use `<repo>`, which is also the CLI's name. |
| `panels` | array of Panel | no | `[]` | The app's panels. An app with none is discovered but has nothing to show. |
| `iconName` | string | no | none | SF Symbol MacHUD shows when the bundle has no icon. A non-string value is ignored. |

### Panel

| Key | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `id` | string | yes | | The panel id used in every `panel` command (`id=`). MacHUD names it `<app id>/<panel id>` (`xyz.machud.tallyhud/main`). |
| `title` | string | no | `id` | Display title. MacHUD also matches it against window titles when it has to move the window through Accessibility. |
| `symbol` | string | no | none (MacHUD uses `app.dashed`) | SF Symbol for menus and the dock. |
| `kind` | `"hover"` \| `"windowed"` | no | `"windowed"` | How the MacHUD tool dock presents it; see [Behaviour](#behaviour-hover-and-windowed). An unknown value reads as `windowed`. |
| `order` | integer | no | none | Sort key within its `kind` group on the dock, ascending; panels without one come after those with one, in manifest order (`HUDManifest.dockSorted`). A non-integer is ignored. Family hover apps use 1-5; the template uses 90. |
| `defaultSize` | `[width, height]` | no | none | Points. MacHUD uses it the first time it places or hover-shows the panel (else 420x480). |
| `compactSize` | `[width, height]` | no | none | Size in `compact` mode, informational. |
| `capabilities` | array of string | no | `[]` | Known values: `acceptsFileDrop` (see [File drops](#file-drops)), `agent-sessions` (see [Agent sessions](#agent-sessions)) and `text-feed` (see [Text feed](#text-feed)). Unknown values are carried but ignored (Scratch lists `acceptsTextDrop`, which MacHUD does not use). |
| `verbs` | array of string | no | `[]` | Informational list of what the panel supports beyond the required commands. **One value has an effect:** MacHUD places the panel with `panel frame` over the socket only when `verbs` is empty or contains `"frame"`; otherwise it moves the window through Accessibility. |
| `settingsSchema` | string | no | none | Path of a [settings schema](#settings-schema) file relative to `Contents/Resources`. The first panel that names one is the app's schema. |

Rules:

- A size that is not exactly two numbers, or a missing `id`/`name`/`socket` (top level) or `id`
  (panel), makes the whole manifest invalid: MacHUD skips the app and lists it under `failures`
  in `machud apps`. Unknown keys are ignored.
- `hello` returns the panels as JSON (`HUDManifest.Panel.json`): every key above, with
  `capabilities` and `verbs` always present and absent optionals omitted.
- An app keeps a `builtinManifest` in code that equals the file (used under `swift run` and in
  tests; `HUDManifest.main` is nil outside a bundle) and a test that asserts they are equal.

## Socket

### Location and permissions

- Path: `HUDSocket.path(for: <socket>)` = `~/Library/Application Support/MacHUD/sockets/<socket>.sock`.
  The directory is created with mode `0700` (and re-chmodded on every call); the socket file is
  `0600`. Only the user can connect.
- Maximum path length: **103 bytes** (`sun_path` is 104 including the terminator,
  `HUDSocket.maxPathLength`). A longer path fails to bind (the server logs `socket path too
  long`) and the CLIs report `socket path too long` with the path (`HUDSocketClient.failureMessage`). Keep socket names short; never put sockets
  under `$TMPDIR` (`/var/folders/...` paths are long).
- An app **must** read `<REPO>_SOCKET` and use it as the socket name instead of `<repo>`, so an
  isolated copy can run beside the real one (the CLI reads it too). The template does.
- On start the server removes a stale socket file, but **refuses to take over a socket another
  live process is serving** (`start()` returns false and logs `another server is already
  listening`). On normal termination (`NSApplicationWillTerminateNotification`) it removes the
  socket file.

### Framing and connections

- One JSON object per line, UTF-8, terminated by `\n`. A final line without `\n` is accepted when
  the client closes its write side.
- Request: `{"command": "<name>", "args": {"<key>": "<value>", ...}}`. `args` is optional.
- **One request per connection**: the server reads one line, writes one reply line and closes
  the connection. The only exception is `subscribe`, which stays open.
- A connection that sends an empty line or hangs up without a line is closed without a reply
  (liveness probes).
- A request line longer than 1,000,000 bytes is cut and answered as a malformed request.
- **Args are strings.** The server converts every arg value with Swift string interpolation
  before a handler sees it: `"x"` → `"x"`, `3` → `"3"`, `1.5` → `"1.5"`, `true` → `"1"`, `false`
  → `"0"`, arrays and objects → an unspecified description. Send strings. Handlers receive
  `[String: String]`.
- Handlers run on the **main thread**, one at a time. A handler that does not answer within
  90 s (`HUDSocketServer.handlerTimeout`) is answered `{"ok": false, "error": "timeout"}`.
- Replies are compact JSON with unordered keys; `/` is escaped as `\/` (JSONSerialization).
  Parse them; do not compare strings.

### Replies

- Success: `{"ok": true, ...}` with command-specific keys.
- Failure: `{"ok": false, "error": "<human-readable message>"}`.

| Situation | Reply |
|---|---|
| Not JSON, or no string `command` | `{"ok": false, "error": "malformed request"}` |
| Unknown command | `{"ok": false, "error": "unknown command <name>", "commands": [...]}` |
| Handler timeout | `{"ok": false, "error": "timeout"}` |
| Command-specific errors | see each verb |

### Built-in `help`

`{"command": "help"}` → `{"ok": true, "commands": ["action", "hello", "menu", "menu-invoke", "panel", "quit", "settings", "state"]}`:
the registered handlers, sorted (HUDKit registers `menu` and `menu-invoke` in every app,
answering `no menu` without a provider). `help` itself and `subscribe` are built into the server
and are not listed.

## Verbs

Required: `hello`, `panel`, `state`, `subscribe`, `settings`, `action`, `quit`
(`HUDControlRouter.requiredVerbs`). Optional: `menu`, `menu-invoke`
(`HUDControlRouter.optionalVerbs`, see [Menu bar consolidation](#menu-bar-consolidation)).
`HUDControlRouter.install()` registers all of them on the server; `subscribe` is served by
`HUDSocketServer` itself. An app may register more commands
(`server.register("name") { args, done in ... }`), but app-specific operations belong under
`action` so that the CLI grammar and MacHUD stay uniform.

Examples below use the TallyHUD app from [AGENT-GUIDE.md](AGENT-GUIDE.md) with panel `main`.
Replies are shown with keys in a readable order.

### hello

```json
{"command": "hello"}
{"ok": true, "hudkit": "0.1.0", "app": "xyz.machud.tallyhud", "name": "TallyHUD", "version": "0.1.0",
 "panels": [{"id": "main", "title": "TallyHUD", "symbol": "number.circle", "kind": "hover", "order": 90,
             "defaultSize": [320, 160], "capabilities": ["acceptsFileDrop"],
             "verbs": ["show", "hide", "toggle", "frame", "mode", "say", "bump", "reset", "drop"],
             "settingsSchema": "settings.json"}],
 "verbs": ["hello", "panel", "state", "subscribe", "settings", "action", "quit", "menu", "menu-invoke"],
 "statusItem": {"visible": false, "consumed": true, "hostFile": "/Users/me/Library/Application Support/MacHUD/host.json",
                "store": "/Users/me/Library/Application Support/TallyHUD/menubar.json",
                "host": {"pid": 93944, "bundleID": "com.jrisberg.machud", "hostsMenus": true, "alive": true}}}
```

- `app`/`name` come from the router's manifest; absent if the router has none.
- `version` is absent outside a bundle (`swift run`).
- `panels` is `host.panelDescriptors` (default: the bundle manifest's panels).
- `verbs` is the seven required verbs, plus `menu` and `menu-invoke` when the app set
  `router.menuProvider`; never the manifest's `verbs`.
- `statusItem` is present once the app attached a `HUDStatusItemPolicy` (`host` only while a
  `host.json` exists).

### state

```json
{"command": "state"}
{"ok": true, "panels": [{"id": "main", "visible": false, "mode": "full", "badge": "3", "status": "Hello from TallyHUD"}]}
```

A panel state (`HUDPanelState.json`):

| Key | Type | Meaning |
|---|---|---|
| `id` | string | panel id |
| `visible` | bool | the panel is meant to be on screen (use a flag, not `window.isVisible`, which stays true during a fade-out) |
| `mode` | `"full"` \| `"compact"` \| `"parked"` | current representation |
| `badge` | string, optional | short count or marker MacHUD may show (e.g. a number) |
| `status` | string, optional | one line describing what the panel shows |
| `frame` | optional | Not produced by `HUDPanelState`. MacHUD accepts `[x,y,w,h]`, `{"x","y","w","h"}` or `"x,y,w,h"` (AppKit screen coordinates) and uses it as the panel's frame for hover hit-testing and HUD capture; a state without it makes MacHUD forget the last one. |

### panel

Args: `id=<panel>` plus a sub-verb given either as `action=<sub>` (what MacHUD sends) or as a bare
key (what the CLI sends: `panel show id=main` → `{"show": "1", "_": "show", "id": "main"}`). With
no sub-verb, `toggle`. Every successful `panel` reply is
`{"ok": true, "visible": <bool>, "mode": "<mode>"}` (the state right after the call) and the
router then pushes a `state` event.

| Sub-verb | Extra args | Host method called |
|---|---|---|
| `show` | optional `from=`, `anchor=`, `reason=` | `showPanel(_:options:)` |
| `hide` | optional `to=`, `anchor=`, `reason=` | `hidePanel(_:options:)` |
| `toggle` | optional `from=`, `to=`, `anchor=`, `reason=` | `togglePanel(_:)` without options, else `togglePanel(_:options:)` (default: hide if visible, passing `from` on as `to` when `to` is absent, else show) |
| `frame` | `x= y= w= h=` (numbers, AppKit screen points, origin bottom-left of the main display) | `setPanelFrame(_:frame:)` |
| `mode` | `mode=full\|compact\|parked` or the bare mode; for `parked` optional `edge=left\|right\|top\|bottom`, `peek=<points>` | `setPanelMode(_:mode:options:)` |

Transition options (`HUDPanelTransition`), sent by MacHUD's tool dock:

| Option | Value | Meaning |
|---|---|---|
| `from` | `left`, `right`, `top`, `bottom` | show: the dock edge to slide out of |
| `to` | same | hide: the edge to slide back toward |
| `anchor` | `x,y,w,h` (exactly four numbers) | the dock button's frame, AppKit screen coordinates |
| `reason` | `hover`, `click`, `summon` | why: the pointer is resting on a hover button; a click; a hotkey, CLI, menu or loadout |

The router validates `from`, `to` and `anchor`; every other key except `id`, `action`, `_`,
`show`, `hide`, `toggle` is passed through in `options` (an unknown `reason` arrives in `options`
and parses as nil).

```json
{"command": "panel", "args": {"action": "show", "id": "main", "from": "bottom", "anchor": "1258,16,44,44", "reason": "hover"}}
{"ok": true, "visible": true, "mode": "full"}

{"command": "panel", "args": {"action": "hide", "id": "main", "to": "bottom", "reason": "hover"}}
{"ok": true, "visible": false, "mode": "full"}

{"command": "panel", "args": {"action": "frame", "id": "main", "x": "1120.0", "y": "78.0", "w": "320.0", "h": "160.0"}}
{"ok": true, "visible": false, "mode": "full"}

{"command": "panel", "args": {"action": "mode", "id": "main", "mode": "parked", "edge": "left", "peek": "12.0"}}
{"ok": true, "visible": true, "mode": "parked"}
```

Errors:

| Request | Error |
|---|---|
| missing or unknown `id` | `no such panel` |
| `from`/`to` not an edge | `from must be left, right, top or bottom` (or `to must ...`) |
| `anchor` not four numbers | `anchor must be x,y,w,h` |
| `frame` without all of `x y w h` | `panel frame needs x= y= w= h=` |
| `frame` on a host that does not implement it | `unsupported: panel frame` |
| `mode` without a valid mode | `panel mode needs compact, full or parked` |
| `mode` with a bad `edge` | `edge must be left, right, top or bottom` |
| `mode` on a host that does not implement it | `unsupported: panel mode` |
| any other sub-verb | `panel action must be one of show, hide, toggle, frame, mode` |
| an error the host throws | its description (`HUDControlError.invalid("frame too small")` → `frame too small`) |

A malformed `peek` is ignored (nil). `mode` and `frame` are optional for an app: without them
MacHUD parks and places the window through Accessibility instead.

### settings

Sub-verb as `action=get|set|schema`, or inferred: a `set` key means set, a `schema` key means
schema, anything else means get.

```json
{"command": "settings", "args": {"action": "get"}}
{"ok": true, "settings": {"greeting": "Hello from TallyHUD", "showCount": true, "defaultStep": 1, "menuBar.consumed": true}}

{"command": "settings", "args": {"action": "get", "key": "greeting"}}
{"ok": true, "key": "greeting", "value": "Hello from TallyHUD"}

{"command": "settings", "args": {"action": "set", "showCount": "false", "greeting": "Hi"}}
{"ok": true, "settings": {"greeting": "Hi", "showCount": false, "defaultStep": 1, "menuBar.consumed": true}}

{"command": "settings", "args": {"action": "set", "key": "greeting", "value": "Yo"}}
{"ok": true, "settings": {"greeting": "Yo", "showCount": false, "defaultStep": 1, "menuBar.consumed": true}}

{"command": "settings", "args": {"action": "schema"}}
{"ok": true, "schema": {"version": 1, "settings": [{"key": "greeting", "title": "Greeting", "type": "string", ...}]}}
```

- `get` values are typed JSON (bools are bools); `set` values arrive as strings.
- `set` removes the keys `action`, `set`, `get`, `schema`, `_` before calling
  `updateSettings`, and turns `key=K value=V` into `K=V`. So a setting must not be named
  `action`, `set`, `get`, `schema`, `_`, `key` or `value`.
- `set` **must** validate every value before applying any (all or nothing) and reply with the
  full settings after the change.
- Once a `HUDStatusItemPolicy` is attached, the router adds `menuBar.consumed` (bool, default
  `true`) to `get`, `set` and `schema` itself, stored where the policy's `store` says; the host
  never sees it. Do not define a setting with that key. Apps attach the policy with
  `store: .home(<data directory>)` (`<data directory>/menubar.json`), so it follows
  `<REPO>_HOME` like the app's other settings; the default, `.defaults(.standard)`, would write
  the user's real preference from a test instance.

| Request | Error |
|---|---|
| `get key=` of an unknown key | `no such setting <key>` |
| `set` with no values | `settings set needs key=value` |
| `set` on a host without `updateSettings` | `unsupported: settings set` |
| `set` with a value the schema rejects | `<key> <reason>` (`delay must be at least 0.1`), before the host sees anything |
| `set` with a bad value or unknown key | the host's message (template: `invalid value maybe for showCount`, `unknown setting colour`) |
| `schema` without a schema | `unsupported: no settings schema` |
| any other sub-verb | `settings action must be get, set or schema` |

### action

App-specific verbs. The verb is either `name=<verb>` (what MacHUD sends) or the CLI's first bare
word (`action bump by=2` → `{"_": "bump", "bump": "1", "by": "2"}`); when both are present the bare
word wins and `name` stays in the payload. The router strips `_`, the bare word's own key and
`name` (when it named the verb), then calls `performAction(_:args:done:)`, which **must** call
`done` exactly once.

```json
{"command": "action", "args": {"name": "bump", "by": "2"}}
{"ok": true, "count": 2}

{"command": "action", "args": {"name": "bump", "by": "lots"}}
{"ok": false, "error": "by must be a whole number, not lots"}
```

| Request | Error |
|---|---|
| no verb | `action verb required: action <verb> or name=<verb>` |
| unknown verb (default host) | `unknown action <verb>` (the template adds the list of known actions) |

Conventions: reply as soon as the request is accepted, not when slow work finishes (the
handler holds the main thread and the caller's connection); return the changed object
(`{"ok": true, "pad": {...}}`); name verbs in lower case with dashes.

### menu and menu-invoke (optional)

Served when the app sets `router.menuProvider` (its status item's menu). The menu is refreshed as
AppKit does before it opens (`menuNeedsUpdate`, validation) and serialized by `HUDMenuBridge`;
ids are index paths (`"2"`, `"5.1"` in a submenu); hidden and alternate items are omitted but keep
their index.

```json
{"command": "menu"}
{"ok": true, "items": [
  {"id": "0", "title": "Show/Hide TallyHUD", "kind": "item", "enabled": true, "state": "off"},
  {"id": "1", "title": "", "kind": "separator", "enabled": false, "state": "off"},
  {"id": "2", "title": "Quit TallyHUD", "kind": "item", "enabled": true, "state": "off", "keyEquivalent": "q", "modifiers": ["command"]}]}

{"command": "menu-invoke", "args": {"id": "0", "title": "Show/Hide TallyHUD"}}
{"ok": true, "id": "0", "title": "Show/Hide TallyHUD"}
```

`kind` is `item`, `separator` or `submenu` (with `items`); `state` is `on`, `off` or `mixed`.
`menu-invoke` replies first, then performs the item on the main thread (so a Quit item still
answers). `id` may also be the bare word (`menu-invoke 0`); `title=` guards against a menu that
changed since it was listed.

| Request | Error |
|---|---|
| no `menuProvider`, or it returned nil | `no menu` |
| `menu-invoke` without `id` | `menu-invoke needs id=` |
| unknown id | `no menu item <id>` |
| a separator or submenu | `menu item <id> is a separator or submenu` |
| a disabled item | `menu item <id> is disabled` |
| `title=` does not match | `menu item <id> changed; list the menu again` |

### quit

```json
{"command": "quit"}
{"ok": true}
```

The reply is written first; then `host.quit()` runs (default `NSApp.terminate(nil)`), and the
socket file is removed on termination. An app **must** quit on `quit`: `hud-install.sh` and
MacHUD's `apps quit` rely on it.

## subscribe and state events

```json
{"command": "subscribe", "args": {"events": "state"}}
{"ok": true, "subscribed": true}
{"event": "state", "panels": [{"id": "main", "visible": true, "mode": "full", "badge": "0", "status": "Hello from TallyHUD"}]}
{"event": "state", "panels": [{"id": "main", "visible": false, "mode": "full", "badge": "0", "status": "Hello from TallyHUD"}]}
```

- The connection stays open; the server pushes one line per published event until either side
  closes. Anything the client writes after the request is ignored.
- `events=a,b` limits the stream to those event names; without it every event is sent. The
  contract defines one event, `state`: `{"event": "state", "panels": [<panel state>, ...]}`
  (`router.publishState()`, all panels, or `router.publishPanel(id)`, one panel).
- The stream carries **changes only**: a subscriber sends `state` once to learn the current
  state (MacHUD does). Events may repeat an unchanged state; consumers must be idempotent.
- The router publishes after every successful `panel` command. The app **must** call
  `router.publishState()` itself whenever panel state changes any other way (hotkey, menu
  item, close button, Esc, an action, a settings change that alters `badge`/`status`). MacHUD's
  dock indicators and hover logic depend on it.

## Settings schema

The file a panel's `settingsSchema` names (`HUDSettingsSchema`), rendered by MacHUD's shared
settings window without launching the app and served by `settings schema`.

```json
{
  "version": 1,
  "settings": [
    {"key": "greeting", "title": "Greeting", "type": "string", "default": "Hello from TallyHUD",
     "help": "What the panel says until `tallyhud say` changes it."},
    {"key": "showCount", "title": "Show how many times the panel was opened", "type": "bool", "default": true},
    {"key": "fadeTime", "title": "Fade time (seconds)", "type": "number", "min": 0.05, "max": 2, "step": 0.05, "default": 0.2},
    {"key": "collisionPolicy", "title": "When names collide", "type": "enum", "group": "Files",
     "options": [{"value": "keepBoth", "title": "Keep both"}, "skip"], "default": "keepBoth"}
  ]
}
```

| Field key | Type | Default | Meaning |
|---|---|---|---|
| `version` (top level) | int | 1 | schema format version |
| `key` | string | required | the setting's key in `settings get/set` |
| `title` | string | `key` | label |
| `type` | `string`, `bool`, `int`, `number`, `enum`, `path` | `string` | control and validation. `number` is a decimal (`Double`). Aliases: `boolean` → bool, `integer` → int, `double`/`float`/`decimal` → number, `text` → string; unknown types read as `string` |
| `default` | JSON string/bool/number | none | shown until the app reports a value |
| `options` | array of `{"value", "title"}` or bare strings | `[]` | `enum` choices |
| `group` | string | none (the app's name) | section heading |
| `help` | string | none | one line under the control |
| `min`, `max` | number | none | `int` and `number`: inclusive bounds `settings set` enforces |
| `step` | number > 0 | none | `int` and `number`: the settings window's stepper increment (MacHUD uses 1 for `int` and 0.1 for `number` without one) |

Wire values for `settings set` (`HUDSettingsSchema.Field.parse`): bool accepts
`true/false/1/0/yes/no/on/off`; int a whole number; number a finite decimal (`0.75`, `2`); both
within `min`/`max` when given; enum one of the option values (any value if there are no
options); string and path anything. `schema.validate(values)` checks all values and rejects
unknown keys. The router's `settings set` checks every value whose key the host's
`settingsSchema` lists before calling `updateSettings` (errors read `autosaveDelay must be at most
10`, `autosaveDelay must be a number`); keys the schema does not list go to the host unchecked.
`settings get` reports a `number` as a JSON number (`0.75`).

## docks.json

`~/Library/Application Support/MacHUD/docks.json` (`HUDDockRegistry.defaultURL`) records where
each dock strip sits, so sibling strips (MacHUD's tool dock, Sift's dock mode) avoid each other.
Only apps that draw their own screen-edge strip use it.

```json
{
  "com.jrisberg.machud": {"position": "topLeft", "frames": [[6, 1140, 64, 264], [6, 1340, 177, 64]],
                          "updatedAt": "2026-09-27T00:43:40.566Z", "pid": 66846},
  "xyz.machud.sift": {"position": "topLeft", "frames": [[6, 794, 64, 340]],
                      "updatedAt": "2026-09-27T00:18:41.847Z", "pid": 67602}
}
```

- Key: the app's bundle id. `position`: one of `top`, `bottom`, `left`, `right`, `topLeft`,
  `topRight`, `bottomLeft`, `bottomRight` (`HUDDockPosition`). `frames`: one `[x, y, w, h]` per
  strip segment (both arms of an L), AppKit screen coordinates. `updatedAt`: ISO 8601.
  `pid`: the publishing process.
- Write only through `HUDDockRegistry`: `publish(appID:position:frames:)` (atomic replace under
  an `flock` on `docks.json.lock`; no write when nothing changed) and `remove(appID:)` when the
  strip goes away. Read with `others(than:)` (entries whose `pid` is dead are ignored) and
  `watch { entries in ... }` (debounced 0.1 s).
- An isolated instance must use its own file: Sift reads `SIFT_DOCKS_FILE` and uses
  `<SIFT_HOME>/docks.json` under `SIFT_HOME`; MacHUD reads `MACHUD_DOCKS_FILE` and uses
  `docks.json` beside `MACHUD_CONFIG`. A second instance publishing under the same bundle id
  overwrites the real instance's entry.

## Behaviour: hover and windowed

The manifest's `kind` tells MacHUD how to present a panel; the app's window behaviour
(`HUDPanelWindow.Behavior`) **must** match it.

### What MacHUD sends

**Hover panels** (`kind: hover`: Scratch, Stash, ffmpegHUD, ...):

1. The pointer rests on the dock button for **60 ms** → MacHUD sends
   `panel frame` (the panel's last size or `defaultSize`, placed next to the button with
   `HUDDockLayout.panelFrame`), then `panel show from=<dock edge> anchor=<button frame> reason=hover`.
   It launches the app first if needed.
2. While the panel shows, the pointer may be anywhere in the dock bar, the panel, or the
   rectangle between them. Outside that for **120 ms** → `panel hide to=<dock edge> anchor=<button> reason=hover`.
3. Moving to another hover button switches at once: the new app's `panel show` goes out first,
   the old app's `panel hide` as soon as the new app has answered (at most **150 ms** later), so
   they cross-fade. Both apps must animate independently.
4. A click pins the panel open (MacHUD stops hiding it on leave); clicking again hides it.
   `machud summon` of a hover app opens it pinned, also with `reason=hover`.

**Windowed panels** (`kind: windowed`: Sift, MechaHUD):

- A click on the button sends `panel frame` (the frame remembered at the last dismiss, if any)
  then `panel show from= anchor= reason=click`; if the panel is visible and frontmost, a click
  sends `panel hide to= anchor= reason=click` instead (a covered or off-Space window is summoned,
  not hidden). MacHUD yields activation to the app just before a click or summon show.
- `machud summon`/`dismiss`, menus, hotkeys and loadouts send `reason=summon`.

### What the app must do

| | Hover | Windowed |
|---|---|---|
| Window | `HUDPanelWindow(contentRect:)` (`.hover`: borderless, non-activating, `.floating`, every Space, never hides on deactivate) | `HUDPanelWindow(contentRect:behavior: .windowed)` (normal level, activates on click, current Space, Mission Control, Dock tile while shown via `HUDDockPolicy`) |
| `reason=hover` show | order in **without** taking focus or activating the app; never steal the keyboard from the app the user is in | not sent |
| `reason=click` / `summon` show | may make the panel key (a keyable non-activating panel does not activate the app) | bring forward and activate: `window.activateOnShow(transition)` |
| Show with `from=` | slide out of that edge: `HUDAnimation.slide(in: window, from: from, to: frame)` (0.22 s ease-out, 24 pt travel, fading in) | same |
| Hide with `to=` | slide back: `HUDAnimation.slideOut(window, toward: to)` (0.18 s ease-in, fading out, then ordered out with frame and alpha restored) | same |
| Show/hide without options | fade in/out in place: `HUDAnimation.fadeIn`/`fadeOut` | same |
| A show arriving mid-hide | the show wins (HUDAnimation's generation token does this; do not order out in your own completion blocks) | same |
| Handlers | return immediately; animate asynchronously | same |

`HUDPanelWindow.activateOnShow(_:)` implements the focus rules for both behaviours: with
`reason=hover` it only orders the window in; otherwise it makes it key, and a windowed window
also activates the app (moving it to the current Space first if needed). Apps may shorten the
hover fades (Scratch and Sift fade a hover show in within 0.08 s and a hover hide out in 0.1 s).

A menu bar app has no main menu, so ⌘C/⌘V/⌘X/⌘A/⌘Z do nothing in its text fields. An app with
any text input **must** call `HUDEditMenu.install(appName:)` at launch. MacHUD does not do this for
other apps.

## File drops

- Opt in per panel with `"capabilities": ["acceptsFileDrop"]` (`HUDDrop.capability`). Only then
  does MacHUD's dock button accept file drags: it highlights, resting **400 ms** opens the panel
  (spring loading), and the drop sends:

  ```json
  {"command": "action", "args": {"name": "drop", "paths": "/Users/me/a%20b.png|/Users/me/c.png"}}
  ```

  plus `"id": "<panel>"` when the app has more than one panel. MacHUD launches the app first if
  needed.
- `paths` encoding (`HUDDrop.encode`): each path is percent-encoded (everything except ASCII
  letters, digits and `/-._~`), then the paths are joined with `|`. Decode with
  `HUDDrop.urls(from: args)`; a segment that is not valid percent-encoding is taken literally and
  `file://` URLs are accepted.
- Reply `{"ok": true, ...}` as soon as the files are accepted (not necessarily processed);
  `{"ok": false, "error": ...}` makes MacHUD reject the drop. **An app that declares the
  capability must handle `action drop`**; otherwise every drop fails with `unknown action drop`.
- `machud tooldock drop id=<app> paths=<HUDDrop.encode or comma-separated plain paths>` performs
  the same drop from the shell.

## Agent sessions

- Opt in per panel with `"capabilities": ["agent-sessions"]` (`HUDAgentSessions.capability`) to
  offer agent sessions (a coding agent's running/idle sessions, e.g. mechaclaude's) that another
  app or the voice host can show and focus without naming this app.
- The panel's app answers two things on its own socket, both app-specific (not part of the
  required verbs):
  - `action name=open-session id=<sessionKey>` (`HUDAgentSessions.openSessionAction`): show and
    focus that session (`performAction`, like any other `action`). `sessionKey` is opaque to
    MacHUD, provider-defined (mechaclaude's is `claude:<sessionId>`).
  - `sessions` (`HUDAgentSessions.sessionsCommand`): a top-level command, registered like `state`,
    answering `{"ok": true, "sessions": [{"id", "title", "cwd", "state"}, ...]}` — the sessions
    the app currently shows. `state` is free-form (e.g. `idle`, `running`, `requires_action`).
    `HUDAgentSession.parseAll(_:)` reads a reply; entries missing `id` or `state` are skipped.
- MacHUD brokers the capability so a client can ask "who shows agent sessions" instead of naming
  an app: `sessions providers` → `{"ok": true, "providers": [{"app", "socket", "running"}, ...]}`
  (every discovered app with a panel declaring the capability), and `sessions open id=<sessionKey>`
  → forwards `action open-session` to the first running provider (launching an installed one if
  none runs) → `{"ok": true, "app": "<bundle id>"}`, or `{"ok": false, "error": "No app shows
  agent sessions"}` when none is discovered. See MacHUD's `docs/API.md`.

## Text feed

- Opt in per panel with `"capabilities": ["text-feed"]` (`HUDTextFeed.capability`) to accept
  finished text (a dictation transcript, an agent reply, ...) into the app's own history, from
  another app or the voice host, without naming this app.
- The panel's app answers one thing on its own socket, app-specific (not part of the required
  verbs): `feed` (`HUDTextFeed.command`), a top-level command like `state`. Its only action,
  `add` (`HUDTextFeed.addAction`, the default when `action` is absent), takes `text=`, `source=`
  (a short label the item is tagged with, e.g. `"Dictation"`, `"Agent"`), and optional `title=`
  and `date=`; it stores the item and replies `{"ok": true, "id": <string>}` (or `{"ok": false,
  "error": ...}`). The app **must not** treat the item as a clipboard write (no re-publishing it
  to the pasteboard, no clipboard-watcher dedup against it).
- MacHUD brokers the capability so a client can send fed text without naming an app: `feed add
  text= source= [title=]` → forwards `feed action=add ...` to every provider whose process is
  already up (never launching one just to feed it) → `{"ok": true, "delivered": [<bundle id>,
  ...]}` (the providers that accepted it; `[]` when none run). See MacHUD's `docs/API.md`.

## Launch announcement

`HUDSocketServer.start()` in an app bundle that has `Contents/Resources/machud.json` sends, once
per process, on a background queue, ignoring every error:

```json
{"command": "apps", "args": {"action": "announce", "path": "/Users/me/dev/tallyhud/build/TallyHUD.app"}}
```

to `MACHUD_SOCKET` if set, else MacHUD's contract socket
`~/Library/Application Support/MacHUD/sockets/machud.sock` (`HUDAnnounce`). `hud-build.sh` sends
the same after every successful build ("Announced to MacHUD" / "MacHUD not running" on stderr).
MacHUD registers the bundle at once (its dock button appears before the app is ever launched) and
remembers it in `apps.known`; an already-known bundle is a no-op. **`HUD_NO_ANNOUNCE=1` turns both
off**: set it for every test build and test launch, or a throwaway build joins the user's dock
(undo with `machud apps forget path=<.app>`). CLIs and test runners have no manifest and never
announce.

## Menu bar consolidation

While MacHUD runs it hosts each app's status menu in its own menu (a submenu per app) and the apps
hide their menu bar icons. The app side is two lines after the status item and router exist:

```swift
control.router.menuProvider = { [weak self] in self?.statusItem.menu }   // serves menu, menu-invoke
HUDStatusItemPolicy.attach(statusItem, appID: control.manifest.id,       // hides the icon while hosted
                           store: .home(AppEnvironment.baseDirectory))   // menuBar.consumed follows <REPO>_HOME
```

- MacHUD writes `~/Library/Application Support/MacHUD/host.json` (`HUDMenuHost`:
  `{pid, bundleID, hostsMenus, updatedAt}`) at launch and every 60 s, with `hostsMenus: false` when
  its `menuBar.consumeSiblings` setting is off, and removes it on quit. `MACHUD_HOST_FILE`
  overrides the path on both sides; an isolated MacHUD writes its own file.
- `HUDStatusItemPolicy` sets `statusItem.isVisible = false` while that file says
  `hostsMenus: true` and its pid is alive, and shows the icon again when MacHUD quits, crashes
  (5 s poll while hidden) or turns the feature off. The app keeps its status item code as is.
- MacHUD fetches the menu with `menu` (cached 3 s), drops the app's own Quit item, and sends
  `menu-invoke id= title=` when the user picks an item (`machud apps menu id=<app>`,
  `machud apps menu-invoke id=<app> item=<id>`).
- The user opts an app out with its `menuBar.consumed` setting (MacHUD's settings window, "Menu
  Bar" group).

## What MacHUD guarantees

What an app gets without writing any code for it (MacHUD's `docs/API.md` has the commands).

- **Discovery.** MacHUD scans `/Applications`, `~/Applications` (each plus one level of plain
  subfolders), every `apps.searchPaths` entry of `~/.config/machud/layouts.json` (`~` and globs
  expand, e.g. `"~/dev/*/build"`) and every bundle in `apps.known` (announced ones, see
  [Launch announcement](#launch-announcement)) for `*.app/Contents/Resources/machud.json`.
  `"standardDirectories": false` skips the first two. It rescans at launch, on
  `machud apps rescan`, on an announcement, and 1 s after an `.app` appears, goes or is replaced
  in a watched directory. Invalid manifests are listed under `failures`. When several bundles
  declare the same `id` (an installed copy and a dev build), the one whose process is running
  wins, else the most recently modified, else the first found; `machud apps` lists them under
  `duplicates`.
- **Supervision.** MacHUD subscribes to each running app's `state` (health `running` when
  subscribed; `socketUnreachable` while the process is up without a subscription; `launching`,
  `notRunning`, `notInstalled`), seeds it with one `state` request, and reconnects a lost
  subscription with backoff (0.5 s doubling to 8 s, up to 8 attempts). Commands for an app that is
  not listening yet are queued for **20 s**; sending one launches the app (without activating
  it). Apps in `apps.autoLaunch` are started with MacHUD and relaunched after an unexpected exit
  (after 2 s, then 4 s; it gives up after 3 launches, `lastError: "gave up ..."`); 60 s of uptime
  resets the count. An app quit through `machud apps quit` (the `quit` verb) is not relaunched.
- **Placement.** Loadout slots and `apps.<id>.placement` place a panel with `panel frame` when it
  is cooperative (listening, and `verbs` empty or containing `frame`), otherwise through
  Accessibility (the window titled like the panel, else the app's main window).
- **Parking.** A parked slot or `machud park` sends `panel frame` with the rest frame, then
  `panel mode id= mode=parked edge=<edge> peek=<points>`; hovering the orb (and `park reveal`)
  sends `panel mode mode=full`. An app without `mode` is parked through Accessibility.
- **Summon and dismiss.** `machud summon id=<app>` shows a panel where it was last dismissed
  (`panel frame`, then `panel show ... reason=summon`); `dismiss` hides it and remembers its frame
  (in `~/.config/machud/state/tooldock.json`). Dismiss never launches an app.
- **HUD loadouts.** `machud capture name=<n> hud=only` records the dock position and, per running
  app, each panel's `visible`, `mode`, frame and (if the app has one) its `dock.position` or
  `dock.edge` setting. Applying it launches missing apps and sends, in order, `settings set`,
  `panel mode`, `panel frame` (not for a parked panel) and `panel show|hide reason=summon`.
- **Settings window.** `machud settings-window show tab=<app>` renders a tab per app from
  `settings schema` over the socket, else the manifest's schema file, reads values with
  `settings get` and writes them with `settings set`. Keys without a schema show as text rows.
- **Tool dock.** One button per app, hover apps first, then windowed, each group by `order`
  then name; running dots from `state`; file drops for `acceptsFileDrop` panels; right-click
  Show/Hide/Park/Place/Quit/Launch/Settings.
- **Menu hosting.** With `menuProvider` and `HUDStatusItemPolicy` in the app, MacHUD shows the
  app's status menu in its own and the app's icon hides ([Menu bar consolidation](#menu-bar-consolidation)).
- **Not provided:** MacHUD does not install an Edit menu, register hotkeys, or restart an app
  that is not `autoLaunch`. An app handles those itself.

## Compliance checklist

Run against a running instance (preferably an isolated one: see
[AGENT-GUIDE.md](AGENT-GUIDE.md#8-verify)). Set `SOCK` to the socket path and `PANEL` to a panel
id, then paste the block into zsh or bash. Every line must print `PASS`. It shows and hides the
panel.

```sh
SOCK="$HOME/Library/Application Support/MacHUD/sockets/tallyhud-test.sock"; PANEL=main
q() { printf '%s\n' "$1" | nc -U "$SOCK"; }
check() { # check <name> <regex the reply must match> <request json>
  local got; got="$(q "$3")"
  if printf '%s' "$got" | grep -Eq -- "$2"; then echo "PASS $1"; else echo "FAIL $1: $got"; fi
}
[ "$(stat -f %Sp "$SOCK")" = "srw-------" ] && echo "PASS socket 0600" || echo "FAIL socket mode $(stat -f %Sp "$SOCK")"
check "hello"               '"hudkit":"0\.4\.[0-9]+"'        '{"command":"hello"}'
check "hello lists panel"   "\"id\":\"$PANEL\""               '{"command":"hello"}'
check "hello verbs"         '"verbs":\["hello","panel","state","subscribe","settings","action","quit"' '{"command":"hello"}'
check "state"               "\"id\":\"$PANEL\""               '{"command":"state"}'
check "help"                '"commands":\['                   '{"command":"help"}'
check "panel show"          '"visible":true'                  "{\"command\":\"panel\",\"args\":{\"action\":\"show\",\"id\":\"$PANEL\"}}"
check "panel hide"          '"visible":false'                 "{\"command\":\"panel\",\"args\":{\"action\":\"hide\",\"id\":\"$PANEL\"}}"
check "hover show"          '"ok":true'                       "{\"command\":\"panel\",\"args\":{\"action\":\"show\",\"id\":\"$PANEL\",\"from\":\"bottom\",\"anchor\":\"600,6,44,44\",\"reason\":\"hover\"}}"
check "hover hide"          '"ok":true'                       "{\"command\":\"panel\",\"args\":{\"action\":\"hide\",\"id\":\"$PANEL\",\"to\":\"bottom\",\"reason\":\"hover\"}}"
check "unknown panel"       '"error":"no such panel"'         '{"command":"panel","args":{"action":"show","id":"no-such-panel"}}'
check "bad from"            '"ok":false'                      "{\"command\":\"panel\",\"args\":{\"action\":\"show\",\"id\":\"$PANEL\",\"from\":\"diagonal\"}}"
check "bad anchor"          '"ok":false'                      "{\"command\":\"panel\",\"args\":{\"action\":\"show\",\"id\":\"$PANEL\",\"anchor\":\"1,2,3\"}}"
check "frame needs x y w h" '"error":"panel frame needs'      "{\"command\":\"panel\",\"args\":{\"action\":\"frame\",\"id\":\"$PANEL\",\"x\":\"1\"}}"
check "settings get"        '"settings":\{'                   '{"command":"settings","args":{"action":"get"}}'
check "settings schema"     '"schema":\{|"error":"unsupported: no settings schema"' '{"command":"settings","args":{"action":"schema"}}'
check "settings set bad"    '"ok":false'                      '{"command":"settings","args":{"action":"set","no.such.setting":"1"}}'
check "action needs verb"   '"error":"action verb required'  '{"command":"action","args":{}}'
check "unknown action"      '"ok":false'                      '{"command":"action","args":{"name":"no-such-action"}}'
check "unknown command"     '"error":"unknown command'        '{"command":"no-such-command"}'
check "malformed request"   '"error":"malformed request"'     'this is not json'
{ printf '%s\n' '{"command":"subscribe","args":{"events":"state"}}'; sleep 1; } | nc -U "$SOCK" > /tmp/hud-sub.$$ & SUB=$!
sleep 0.3; q "{\"command\":\"panel\",\"args\":{\"action\":\"toggle\",\"id\":\"$PANEL\"}}" >/dev/null
q "{\"command\":\"panel\",\"args\":{\"action\":\"toggle\",\"id\":\"$PANEL\"}}" >/dev/null; wait $SUB
grep -q '"subscribed":true' /tmp/hud-sub.$$ && grep -q '"event":"state"' /tmp/hud-sub.$$ \
  && echo "PASS subscribe" || echo "FAIL subscribe: $(cat /tmp/hud-sub.$$)"; rm -f /tmp/hud-sub.$$
```

Then, if the app set `menuProvider`; for a panel with `acceptsFileDrop`; and last of all `quit`:

```sh
check "menu"   '"items":\['  '{"command":"menu"}'
check "drop"   '"ok":true'   '{"command":"action","args":{"name":"drop","paths":"/tmp/a%20b.txt|/tmp/c.txt"}}'
check "quit" '"ok":true' '{"command":"quit"}'; sleep 1
[ -e "$SOCK" ] && echo "FAIL socket left behind" || echo "PASS quit removed the socket"
```

Beyond the socket, a compliant app also:

- [ ] ships `machud.json` that decodes (`HUDManifest.decode`), with `socket` = CLI name = repo name,
      and a `builtinManifest` equal to it (a test asserts both);
- [ ] uses the window behaviour matching each panel's `kind`, and never takes focus on
      `reason=hover`;
- [ ] calls `router.publishState()` on every state change that does not come through `panel`;
- [ ] reads `<REPO>_HOME`, `<REPO>_SOCKET`, `<REPO>_NO_HOTKEYS` (and is tested with
      `HUD_NO_ANNOUNCE=1`);
- [ ] sets `router.menuProvider` and attaches `HUDStatusItemPolicy` (menu bar consolidation);
- [ ] installs `HUDEditMenu` if it has text input;
- [ ] handles `action drop` if any panel declares `acceptsFileDrop`;
- [ ] answers every handler quickly (nothing slow on the main thread).

Checked on 2026-09-26 against the template app, the TallyHUD worked example and the Scratch dev
build over isolated sockets: every socket check passes. Rechecked the same day against the
Scratch and Sift dev builds after they gained `action drop`: every line passes, `drop` included.
