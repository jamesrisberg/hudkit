# __PRODUCT__

A MacHUD app: one hover panel that shows a greeting. Replace this line with what __PRODUCT__ does,
in one sentence. macOS 14+.

## What it is

__PRODUCT__ is a menu bar app (no Dock icon) with one panel on HUD glass. On its own it shows the
panel from the menu bar icon or a hotkey; inside MacHUD it
is a hover button in the tool dock whose panel slides out while the pointer is over it.

## Install

Check out HUDKit (the shared kit and build scripts) next to this repo, then install:

```sh
ls ~/dev            # hudkit  __REPO__
~/dev/__REPO__/install.sh
```

`install.sh` builds a release, quits a running copy, installs `/Applications/__PRODUCT__.app`, links
the `__REPO__` command onto your PATH and launches it.

## Use

| Key | Does |
|---|---|
| Control-Option-H | show or hide the panel |

The menu bar icon (sparkles) does the same and has Quit; while MacHUD runs the icon hides and
MacHUD shows this menu in its own (turn `menuBar.consumed` off to keep the icon). In the MacHUD dock, hover the button to
see the panel. __PRODUCT__ takes no drops (a panel that does lists `acceptsFileDrop` in its manifest
capabilities and handles `action drop`).

## MacHUD contract

Panel `main`, kind `hover`, socket `__REPO__`. Verbs: the HUDKit set (`hello`, `state`, `subscribe`,
`panel show|hide|toggle|frame`, `settings get|set|schema`, `action`, `quit`) plus `action say`.
Full reference: [docs/CONTRACT.md](docs/CONTRACT.md).

```sh
__REPO__ hello
__REPO__ say text="Build finished"
__REPO__ panel toggle id=main
__REPO__ settings set showCount=0
__REPO__ quit
```

## Settings

| Key | Type | Default | |
|---|---|---|---|
| `greeting` | string | `Hello from __PRODUCT__` | what the panel says until `say` changes it |
| `showCount` | bool | `true` | show how many times the panel was opened |
| `menuBar.consumed` | bool | `true` | hide the menu bar icon while MacHUD hosts the menu |

Set them in MacHUD's settings window or with `__REPO__ settings set key=value`. Stored in
`~/Library/Application Support/__PRODUCT__/preferences.json`.

## Build from source

Needs Swift 5.9+ and HUDKit checked out next to this repo (`../hudkit`).

```sh
swift test          # __PRODUCT__KitTests + __PRODUCT__Tests
./build.sh          # build/__PRODUCT__.app (release; ./build.sh debug for a debug build)
./install.sh        # build, install to /Applications, link the CLI, launch
.build/debug/__PRODUCT__ --snapshot /tmp/__REPO__.png   # write a PNG of the panel and quit
```

Build it and it shows up in the dock: with MacHUD running, `./build.sh` announces the new bundle
and its button appears in the tool dock at once, before you launch it (`HUD_NO_ANNOUNCE=1` skips).

`build.sh` and `install.sh` call HUDKit's shared `scripts/hud-build.sh` and `scripts/hud-install.sh`
(set `HUDKIT_DIR` if HUDKit lives elsewhere). The version comes from [VERSION](VERSION); changes
are in [CHANGELOG.md](CHANGELOG.md).

The app and menu bar icons (`AppIcon.icns`, `MenuBarIcon.png`, `MenuBarIcon@2x.png` in
`Sources/__PRODUCT__/Resources`) start as HUDKit's placeholder. Draw the app's glyph in
`../hudkit/Icons/__REPO__.svg` (see its README) and run `../hudkit/scripts/hud-icon.sh __REPO__ .`

## Isolation env vars for testing

| Variable | Effect |
|---|---|
| `__REPO_UPPER___HOME` | base directory for everything __PRODUCT__ writes (default `~/Library/Application Support/__PRODUCT__`) |
| `__REPO_UPPER___SOCKET` | socket name (default `__REPO__`); the CLI honours it too |
| `__REPO_UPPER___NO_HOTKEYS` | set to skip registering global hotkeys |

```sh
__REPO_UPPER___HOME=$(mktemp -d) __REPO_UPPER___SOCKET=__REPO__-test __REPO_UPPER___NO_HOTKEYS=1 .build/debug/__PRODUCT__ &
__REPO_UPPER___SOCKET=__REPO__-test .build/debug/__PRODUCT__CLI hello
```

## License

MIT, see [LICENSE](LICENSE).
