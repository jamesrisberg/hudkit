# __PRODUCT__'s MacHUD contract

__PRODUCT__ implements the MacHUD contract through HUDKit. MacHUD reads
`__PRODUCT__.app/Contents/Resources/machud.json` without launching the app and talks to the running
app over a Unix socket. The shared parts (socket framing, the required verbs' requests, replies
and errors, `subscribe`, the settings schema format, what MacHUD sends and expects) are specified
in HUDKit's [docs/CONTRACT.md](../../hudkit/docs/CONTRACT.md); this page lists what __PRODUCT__ adds.

- Manifest: `Sources/__PRODUCT__/Resources/machud.json`: app `xyz.machud.__REPO__`, socket
  `__REPO__`, one panel `main` (`kind: hover`, `order: 90`, symbol `sparkles`, default 320x160,
  settings schema `settings.json`).
- Hover: `panel show from=<edge> anchor=x,y,w,h` slides the panel out of the dock next to the
  button (`HUDPanelTransition.panelFrame`, `HUDAnimation.slide(in:)`); `panel hide to=<edge>` slides
  it back while fading out. Without options it fades in or out where it is. It never takes focus.
- Socket: `~/Library/Application Support/MacHUD/sockets/__REPO__.sock` (0600); framing and error
  replies as in HUDKit's CONTRACT.md.
- CLI: `__REPO__ <command> [key=value ...]` (in `__PRODUCT__.app/Contents/Helpers/__REPO__`, linked
  onto PATH by `install.sh`; grammar and exit codes in HUDKit's docs/CLI.md). `say` is shorthand
  for `action name=say`.

## Verbs

| Command | Args | Result |
|---|---|---|
| `hello` | | `{app, name, hudkit, version, panels, verbs}`: `hudkit` is the contract version, `version` the app's |
| `state` | | `{panels: [{id: "main", visible, mode, status}]}`: `status` is the text shown |
| `subscribe` | `events=state` (optional) | acknowledged, then `{"event": "state", ...}` on visibility, text and settings changes |
| `panel show` / `hide` / `toggle` | `id=main`, plus MacHUD's `from=`/`to=`/`anchor=`/`reason=` | see Hover |
| `panel frame` | `id=main x= y= w= h=` | AppKit screen coordinates; at least 100x60 |
| `settings get` | `key=` (optional) | `{settings: {greeting, showCount, menuBar.consumed}}` |
| `settings set` | `key=value ...` | validates every value before applying any |
| `settings schema` | | `{schema}` from `settings.json` |
| `action say` | `text=` (optional) | shows `text`; empty or missing goes back to the greeting. `{text}` |
| `action show` / `hide` / `toggle` | | same as the panel verbs |
| `menu` / `menu-invoke` | `id=` (and optional `title=`) for `menu-invoke` | the status menu, so MacHUD can host it (menu bar consolidation) |
| `quit` | | replies, then quits (the socket file is removed) |
| `help` | | lists the registered commands |

## Settings

| Key | Type | Default |
|---|---|---|
| `greeting` | string | `Hello from __PRODUCT__` |
| `showCount` | bool | `true` |

| `menuBar.consumed` | bool | `true`: hide the menu bar icon while MacHUD hosts the menu (served by HUDKit) |

Stored in `<home>/preferences.json` (`menuBar.consumed` in `<home>/menubar.json`), where home is
`~/Library/Application Support/__PRODUCT__` or `$__REPO_UPPER___HOME`. Saved values are merged over
the defaults key by key: a setting added later, or a saved value that does not decode, takes
its default and leaves the others alone.

## Menu bar consolidation

While MacHUD runs it shows __PRODUCT__'s status menu inside its own (`menu`, `menu-invoke`) and the
menu bar icon hides (`HUDStatusItemPolicy`); the icon comes back when MacHUD quits or the user
turns `menuBar.consumed` off. `HUDEditMenu` is installed at launch so ⌘C/⌘V/⌘X/⌘A/⌘Z work in text
fields.

## Environment

| Variable | Read by | Effect |
|---|---|---|
| `__REPO_UPPER___HOME` | app | base directory for everything the app writes |
| `__REPO_UPPER___SOCKET` | app, CLI | socket name instead of `__REPO__` |
| `__REPO_UPPER___NO_HOTKEYS` | app | skip global hotkeys |

## Launch flags

| Flag | Effect |
|---|---|
| `--snapshot <path.png>` | show the panel, write a PNG of it after 1 s, print the path and quit; serves no socket, announces nothing, registers no hotkey and adds no menu bar item |
