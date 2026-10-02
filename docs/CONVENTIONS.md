# MacHUD app repo conventions

How every app in the MacHUD family (Sift, Stash, Scratch, MechaHUD, ffmpegHUD, magickHUD,
serversHUD, and the next one) lays out its repo, builds, versions and documents itself. The
rules come from what the apps already do; where they differed, the most common or most useful
variant won. `Templates/App` is the executable form of this document: `scripts/hud-new-app.sh`
turns it into a new repo that follows every rule below. What the app serves over its socket is
specified in [CONTRACT.md](CONTRACT.md); how to build one out, step by step, is
[AGENT-GUIDE.md](AGENT-GUIDE.md).

## Names

| Thing | Rule | Sift | ffmpegHUD |
|---|---|---|---|
| Repo (directory) | lowercase, letters and digits | `sift` | `ffmpeghud` |
| Product | the displayed name, also the Swift target prefix | `Sift` | `ffmpegHUD` |
| Bundle id | `xyz.machud.<repo>` | `xyz.machud.sift` | `xyz.machud.ffmpeghud` |
| Socket | `<repo>` (`~/Library/Application Support/MacHUD/sockets/<repo>.sock`) | `sift` | `ffmpeghud` |
| CLI | `<repo>`, shipped as `Contents/Helpers/<repo>` | `sift` | `ffmpeghud` |
| Env var prefix | `<REPO>_` (uppercase repo) | `SIFT_` | `FFMPEGHUD_` |
| App bundle | `<Product>.app`, executable `Contents/MacOS/<Product>` | `Sift.app` | `ffmpegHUD.app` |

Platform: macOS 14 minimum (`.macOS(.v14)`, `LSMinimumSystemVersion` 14.0), `swift-tools-version:5.9`.
HUDKit is a sibling checkout: `.package(path: "../hudkit")`.

The CLI lives in `Contents/Helpers` because `Contents/MacOS/sift` and `Contents/MacOS/Sift` are
the same file on a case-insensitive volume.

## Layout

```
<repo>/
  Package.swift
  VERSION                         0.1.0
  CHANGELOG.md                    Keep a Changelog
  README.md                       fixed sections, below
  LICENSE                         MIT
  .gitignore
  build.sh  install.sh            two-line shims into ../hudkit/scripts
  <Product>.entitlements          optional; applied by hud-build.sh when present
  .github/workflows/ci.yml        = hudkit/scripts/hud-ci.yml
  docs/
    CONTRACT.md                   socket verbs, actions, settings keys, env vars, launch flags
    ARCHITECTURE.md               optional
  Sources/
    <Product>Kit/                 pure library: models, parsing, persistence, the logic worth testing
    <Product>/                    the app: AppDelegate, ControlHost (HUDPanelHost), panels, views
      Resources/
        Info.plist
        machud.json               the MacHUD manifest
        settings.json             HUDSettingsSchema for MacHUD's settings window
        AppIcon.icns              from hud-icon.sh; hud-build.sh sets CFBundleIconFile when present
        MenuBarIcon.png, @2x      from hud-icon.sh: the status item's template glyph
    <Product>CLI/                 thin socket client (HUDSocketClient.runCLI)
  Tests/
    <Product>KitTests/            unit tests of the Kit
    <Product>Tests/               @testable import <Product>: host logic, manifest/schema/plist checks
```

### Package.swift targets

| Target | Kind | Depends on | Notes |
|---|---|---|---|
| `<Product>Kit` | library | Foundation (HUDKit only if unavoidable) | No AppKit UI. Also a product, so a sibling can reuse it (Stash uses Sift's Kit). |
| `<Product>` | executable | `<Product>Kit`, HUDKit | `exclude: ["Resources"]`: the bundle files are assembled by the build script, not SwiftPM. |
| `<Product>CLI` | executable | HUDKit (and the Kit if it formats output) | `main.swift`: shorthands, then `exit(HUDSocketClient.runCLI(...))`. Honours `<REPO>_SOCKET`. |
| `<Product>KitTests` | test | `<Product>Kit` | |
| `<Product>Tests` | test | `<Product>`, `<Product>Kit`, HUDKit | Includes the manifest test: `machud.json` decodes, `socket == <repo>`, the built-in manifest mirrors the file, the settings schema keys match the Kit's. |

An app with nothing worth a CLI may omit `<Product>CLI`; the build script then ships no helper.

### Info.plist

In `Sources/<Product>/Resources/Info.plist`: `CFBundleExecutable` = `<Product>`,
`CFBundleIdentifier` = `xyz.machud.<repo>`, `CFBundleName`/`CFBundleDisplayName` = `<Product>`,
`LSUIElement` true (menu bar app, no Dock icon), `LSMinimumSystemVersion` 14.0,
`NSHighResolutionCapable` true, `NSHumanReadableCopyright` "Copyright <year> <author>. MIT License.",
`CFBundleIconFile` = `AppIcon`.
`CFBundleShortVersionString` and `CFBundleVersion` are placeholders: `hud-build.sh` writes
`VERSION` and the commit count into the built copy.

## Runtime conventions

- **Contract** ([CONTRACT.md](CONTRACT.md)): the app serves HUDKit's required verbs through
  `HUDControlRouter` from a `ControlHost: HUDPanelHost`, keeps a `builtinManifest` that mirrors
  `machud.json` (used under `swift run` and in tests), and implements
  `showPanel/hidePanel(_:options:)` with `HUDPanelTransition` so it slides out of the MacHUD dock.
- **Hover panels** never take focus on a `reason=hover` show (nor on an option-less socket
  show); `reason=click|summon` may make them key.
- **Window behaviour**: windowed apps use `.windowed`; hover apps use `.hover`
  (`HUDPanelWindow.Behavior`, matching the manifest panel's `kind`). A `.windowed` main window
  is a normal window: `.normal` level, activates the app when clicked, key and main, current
  Space only, in Mission Control and the ⌘` cycle, and a Dock tile / ⌘-Tab entry while it is on
  screen (`HUDDockPolicy`, opt out with `showsInDock = false`). Hover panels, dock strips and
  drawers stay `.hover` (floating, every Space, non-activating). Show the window with
  `activateOnShow(transition)`: `reason=hover` never steals focus, click/summon activate.
- **Widgets** (optional, any app): each widget type is a `kind: widget` manifest panel (also in
  `builtinManifest`) with a view registered on a `HUDWidgetHost`, set as `router.widgetHost`
  before the socket starts. HUDKit makes the windows (`.widget`: desktop layer or floating,
  every Space, never focused, locked outside MacHUD's edit mode); the app keeps no widget state
  of its own beyond what MacHUD sends. Per-instance settings schemas are named
  `<type>.widget.json` in `Resources`. See [CONTRACT.md § Widgets](CONTRACT.md#widgets).
- **Env isolation** (every app, read in one `AppEnvironment` enum):
  - `<REPO>_HOME`: base directory for everything the app writes (default
    `~/Library/Application Support/<Product>`); an isolated instance also keeps its panel frames
    out of the real defaults.
  - `<REPO>_SOCKET`: socket name instead of `<repo>`; the CLI honours it too.
  - `<REPO>_NO_HOTKEYS`: set to skip global hotkeys.
  - `HUD_NO_ANNOUNCE=1` (read by HUDKit and `hud-build.sh`, not the app): no launch or build
    announcement to MacHUD, so a test instance stays out of the user's dock.
- **`--snapshot <path.png>`**: shows the main panel, writes a PNG of its content (over a dark
  stand-in for the glass, which needs Screen Recording to capture) and quits. For docs and UI
  checks. Extra flags that pick what to picture (`--select`, `--snapshot-mode`) are app-specific.
  Launch it with the isolation variables set. A snapshot only draws: it serves no control
  socket and so announces nothing, registers no hotkey, adds no menu bar item, and reads no
  token or other secret (the app returns before that setup, or builds its model offline).
  (The template and MechaHUD quit; the other apps keep running afterwards, see the list at the
  end.)
- **Settings** live in `<home>/preferences.json`, described by `settings.json`; values arrive
  as strings and are validated all-or-nothing before any is applied.

## Menu bar consolidation

While MacHUD runs it hosts every sibling's status menu inside its own (a submenu per app), so the
siblings hide their own menu bar icons. Two lines in the app, after the status item and the
router exist:

```swift
control.router.menuProvider = { [weak self] in self?.statusItem.menu }   // `menu`, `menu-invoke`
HUDStatusItemPolicy.attach(statusItem, appID: manifest.id,               // hide while MacHUD hosts
                           store: .home(AppEnvironment.baseDirectory))  // opt-out in <home>/menubar.json
```

- **`menu`** returns the status menu serialized by `HUDMenuBridge`:
  `{ok, items:[{id, title, kind: item|separator|submenu, enabled, state: on|off|mixed,
  keyEquivalent?, modifiers?, items?}]}`. Ids are index paths (`"5.1"`); hidden and alternate
  items are omitted but keep their index. The menu is refreshed first exactly as when it opens
  (delegate `menuNeedsUpdate`, then validation), so keep titles and check marks current there.
- **`menu-invoke id= [title=]`** replies `{ok, id, title}` and then performs the item on the main
  thread (so a Quit item still answers). `title=` guards against a menu that changed since it was
  listed (`menu item 3 changed; list the menu again`). Separators, submenus and disabled items
  are refused. Apps without a provider answer `{ok:false, error:"no menu"}`; `hello` lists the
  two verbs only when a provider is set.
- **`host.json`** (`~/Library/Application Support/MacHUD/host.json`, `HUDMenuHost`):
  `{pid, bundleID, hostsMenus, updatedAt}`. MacHUD writes it at launch and every 60 s, with
  `hostsMenus: false` when its `menuBar.consumeSiblings` is off, and removes it on quit.
  `MACHUD_HOST_FILE` points both sides elsewhere (isolated instances).
- **`HUDStatusItemPolicy`** sets `statusItem.isVisible = false` while that file says
  `hostsMenus: true` and its pid is alive and still that bundle; it watches the file and, while
  hidden, re-checks every 5 s and on every app termination so a crashed MacHUD gives the icon
  back. `hello` reports it as `statusItem: {visible, consumed, hostFile, store, host?}`.
- **Opt out** per app with the `menuBar.consumed` setting (default true): the router serves it
  through `settings get|set|schema`, so it appears in MacHUD's settings window under "Menu Bar".
  Apps attach the policy with `store: .home(<data directory>)`, which keeps it in
  `<data directory>/menubar.json`, so under `<REPO>_HOME` an isolated instance writes its own
  copy, never the user's.
- The app keeps its status item code as is: with MacHUD gone (or consolidation off) the icon is
  shown and works as usual. No private API is involved; nothing reorders or hides other
  apps' items.

## Icons

One system for the family, described in [Icons/README.md](../Icons/README.md): a dark glass
squircle tile, one accent colour per app and one single-weight glyph with a soft glow. The
sources are `hudkit/Icons/<repo>.svg`; the rendered files are committed in the app repo.

```sh
../hudkit/scripts/hud-icon.sh <repo> .                      # from the app repo
../hudkit/scripts/hud-icon.sh <repo> . --preview /tmp/i.png # plus a 16-128 px / menu bar check sheet
```

writes `Sources/<Product>/Resources/AppIcon.icns` (16-512 pt, @1x and @2x) and
`MenuBarIcon.png`/`MenuBarIcon@2x.png` (18 pt, black on clear). The status item uses
`HUDStatusIcon.image(fallbackSymbol:accessibilityDescription:)`: the bundled glyph as a
template image, the SF Symbol when the resource is missing (`swift run`). Rerun the script
after editing the SVG and commit the three files. Needs `rsvg-convert` and ImageMagick.

## Build and install

`build.sh` and `install.sh` are shims; the logic lives once, in `hudkit/scripts`:

```sh
# build.sh
#!/bin/zsh
cd "${0:A:h}" && exec "${HUDKIT_DIR:-../hudkit}/scripts/hud-build.sh" <Product> "$@"
```

```sh
# install.sh
#!/bin/zsh
cd "${0:A:h}" && exec "${HUDKIT_DIR:-../hudkit}/scripts/hud-install.sh" <Product> "$@"
```

| Script | Does |
|---|---|
| `hud-build.sh <Product> [release\|debug]` | `swift build` of `<Product>` (and `<Product>CLI`), assembles `build/<Product>.app` (MacOS, Resources — including every `*.bundle` SwiftPM produced for the build, found via `swift build --show-bin-path`, so a Kit's bundled companion or model data ships too — Helpers/<repo>, Info.plist with the version), signs with the first "Apple Development" identity (hardened runtime, `<Product>.entitlements` if present) or ad-hoc, prints the app path last. `HUD_SIGN_IDENTITY` overrides the identity (`-` = ad-hoc). `HUD_HELPERS="<product> …"` also builds those executable products into `Contents/Helpers/<product>`, signed with the app's entitlements (for a process the app runs itself), with a relative link to each SwiftPM resource bundle beside it, since a helper's `Bundle.main` is `Contents/Helpers`. Every `@rpath` framework the app or a helper links is copied from the bin path into `Contents/Frameworks` and signed first; a dylib with an absolute install name (Homebrew) is not bundled. |
| `hud-install.sh <Product>` | release build, quits a running copy (`<repo> quit` when the socket answers, else AppleScript), copies to `/Applications`, links the CLI into the first writable PATH dir (`/opt/homebrew/bin`, `/usr/local/bin`, `~/bin`, `~/.local/bin` preferred), launches. `HUD_APPLICATIONS` and `HUD_NO_LAUNCH` for testing. A repo with install needs of its own adds `scripts/install-hooks.sh` (sourced after the build: `hud_install_before_quit <app>`, `HUD_EXTRA_LINKS="scripts/a scripts/b"`) instead of forking the script. |
| `hud-icon.sh <repo> [dir] [--preview png]` | renders `Icons/<repo>.svg` (or the placeholder `Icons/template.svg`) into `AppIcon.icns` and the menu bar PNGs; see **Icons**. |
| `hud-new-app.sh <repo> <Product> [parent]` | new repo from `Templates/App` next to HUDKit, placeholders filled, CI installed, `git init`, first commit. |
| `hud-release.sh <Product> [version] [--dry-run]` | a signed, notarized GitHub release and catalog entry; see **Releasing**. `--check` reports what is configured. |
| `hud-catalog.sh set\|hudkit\|show` | edits MacHUD's app catalog, `machud/site/catalog.json`; see **Releasing**. |
| `hud-ci.yml` | the CI workflow: `swift test` on `macos-26` with HUDKit checked out at `../hudkit`. Copy verbatim to `.github/workflows/ci.yml`. |

All scripts are zsh with `set -euo pipefail`.

## README

Fixed sections, in this order (the template has them filled in):

1. **What it is**: one paragraph; the kind of panel (hover or windowed).
2. **Install**: HUDKit next to the repo, `./install.sh`.
3. **Use**: hotkeys table, menu bar, drag and drop (what the dock button accepts).
4. **MacHUD contract**: panel ids and kind, socket, the app's verbs, CLI examples; link to `docs/CONTRACT.md`.
5. **Settings**: key, type, default, meaning; where they are stored.
6. **Build from source**: `swift test`, `./build.sh [debug]`, `./install.sh`, `--snapshot`.
7. **Isolation env vars for testing**: the three `<REPO>_` variables, with an example.
8. **License**: MIT.

App-specific sections (Sift's rules, ffmpegHUD's presets) go between **Use** and **MacHUD contract**.

`docs/CONTRACT.md` is the app's reference: manifest summary, hover/transition behaviour, a verbs
table (`Command | Args | Result`), settings, environment, launch flags. For the shared parts
(socket location and framing, the required verbs' shapes, `subscribe`, the settings schema
format) it links to HUDKit's [CONTRACT.md](CONTRACT.md) instead of restating them, and it
documents only what the app adds or does differently.

## Versions

- `VERSION` holds the app's semantic version; it is the only place it is written. The first
  release of each app is **0.1.0**.
- `CHANGELOG.md` follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/): an
  `[Unreleased]` section on top, then `## [x.y.z] - YYYY-MM-DD` with Added / Changed / Fixed /
  Removed. A release is: move Unreleased into a new version section, then `hud-release.sh <Product>
  x.y.z` (bumps `VERSION`, commits `<Product> x.y.z`, tags `vx.y.z`, publishes; see
  **Releasing**).
- `hello` reports two versions: `hudkit`, the contract version the app was built against
  (`HUDKit.version`), and `version`, the app's own (`CFBundleShortVersionString`, i.e. `VERSION`).
  MacHUD gates contract features on `hudkit`, never on `version`.
- HUDKit's own `VERSION` equals `HUDKit.version`. A contract addition bumps the minor (0.1 → 0.2)
  while HUDKit is 0.x; additive API or fixes bump the patch.

## Releasing

A release is a Developer ID signed, notarized `<Product>-<version>.zip` on the repo's GitHub
release `v<version>`, listed in MacHUD's catalog. One command, from the app repo:

```sh
../hudkit/scripts/hud-release.sh --check          # identity, credentials, gh, catalog: all "ok"?
../hudkit/scripts/hud-release.sh Sift --dry-run   # build, sign, zip; stop before notarization
../hudkit/scripts/hud-release.sh Sift             # release VERSION
../hudkit/scripts/hud-release.sh Sift 0.2.0       # write 0.2.0 to VERSION, commit "Sift 0.2.0", release it
```

Before running it, move `[Unreleased]` in `CHANGELOG.md` into `## [x.y.z] - date` (the
section becomes the release notes; the script refuses a version without one) and push.

What it does:

1. Builds a clean copy of `HEAD` in a temporary directory (a detached worktree; uncommitted
   work in the checkout is not released), with each `../<dep>` path package exported next to
   it: HUDKit (and a `../hudkit/Kits/<Kit>` package) at HUDKit's newest `v*` tag (`HUDKIT_REF`
   overrides), other siblings at the remote branch their checkout tracks, else `origin/main`
   (`HUD_DEP_REF` overrides): Stash's Sift at `origin/main`, MacHUD's SpeakFree at
   `origin/integration/machud`. The release notes say which. `--ref <commit>` releases
   another commit than `HEAD` (with `VERSION` and the notes read from it), e.g.
   `--ref origin/main` while unpublished local commits are ahead; the commit must be on origin.
2. The repo's `build.sh` (so its settings, such as MacHUD's `HUD_HELPERS`, apply; each named
   helper must be in the bundle), which runs `hud-build.sh`, with the "Developer ID
   Application" identity: hardened runtime, `--timestamp`, `<Product>.entitlements` when present, the helper CLI signed first.
3. `ditto -c -k --keepParent` (without extended attributes: AppleDouble `._` files in a zip
   break the signature when something other than ditto unpacks it), `xcrun notarytool submit
   --wait`. A rejected submission prints the notarization log's issues and stops: nothing is
   tagged or published.
4. `stapler staple`, `spctl -a -vv -t install`, the final zip, a check that a plain `unzip` of
   it passes `codesign --verify`, sha256 and size.
5. Annotated tag `v<version>` on the released commit, pushed; `gh release create` with the zip and the
   CHANGELOG section. Re-running is safe: an existing tag must be at the released commit, an existing
   release gets its notes and asset replaced (`gh release upload --clobber`), and the catalog
   entry is overwritten.
6. `hud-catalog.sh set <repo> <version> <url> <sha256> <size>`: the app's catalog entry.

In HUDKit (no app bundle) the script only tags and creates the release from the CHANGELOG, then
sets the catalog's `hudkit`. The release builds never announce themselves to a running MacHUD.

**Credentials.** Notarization uses an app-specific password, not a keychain profile. The script
reads `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_SPECIFIC_PASSWORD` (`KEY=value` lines; only those
keys are read and the file is never sourced) from the first of `$HUD_ENV_FILE`, `.env` in the
repo, `~/.config/machud/release.env`; variables already in the environment win. Keep the file
`chmod 600` and out of git (every repo ignores `.env`). The signing identity is the keychain's
"Developer ID Application" identity of `APPLE_TEAM_ID` (`HUD_RELEASE_IDENTITY` overrides).
`gh` must be logged in with `repo` scope.

**The catalog.** `machud/site/catalog.json`, served by GitHub Pages (deployed by
`machud/.github/workflows/pages.yml` on every push that changes `site/`) at
<https://jamesrisberg.github.io/machud/catalog.json>. MacHUD reads it to install and update the
family; nothing else is involved in updating.

```json
{ "schemaVersion": 1, "updatedAt": "2026-09-26T12:00:00Z", "hudkit": "0.1.0",
  "apps": [ { "id": "xyz.machud.stash", "repo": "stash", "name": "Stash", "kind": "hover",
              "summary": "Clipboard history as a hover panel", "version": "0.1.0", "minOS": "14.0",
              "download": "https://github.com/jamesrisberg/stash/releases/download/v0.1.0/Stash-0.1.0.zip",
              "sha256": "…", "size": 2412345, "publishedAt": "2026-09-26T12:00:00Z",
              "icon": "https://raw.githubusercontent.com/jamesrisberg/hudkit/main/Icons/stash.svg",
              "homepage": "https://github.com/jamesrisberg/stash", "bundled": true } ] }
```

`kind` is `umbrella` (MacHUD), `hover` or `windowed` (the manifest's first panel). `bundled`
marks the tools MacHUD offers to install by default: every hover app; the windowed apps (Sift,
MechaHUD, Wormhole) are optional. `hud-catalog.sh set` fills what it is not given from the
existing entry, then from the app repo (Info.plist, `machud.json`, the GitHub description); it
edits a temporary worktree of machud at `origin/main`, commits `Catalog: <Name> <version>` and
pushes, so a machud checkout with work in progress is untouched. `hud-catalog.sh hudkit <v>`
sets the HUDKit version; `show` prints the published file.

**No Sparkle.** The apps carry no Sparkle framework and no `SU*` keys in `Info.plist` (the
release script refuses a bundle with `SUFeedURL`): MacHUD compares each installed app's
`CFBundleShortVersionString` with the catalog and installs the zip after checking its sha256.
Wormhole keeps its own Sparkle feed.

## Commits

- One logical change per commit; subject in the present tense, starting with the area when it
  helps (`Manifest: order 1 in the MacHUD dock`, `HUDAnimation.slide(in:)/slideOut take a duration`).
  No type prefixes (`feat:`), no trailing period.
- The body says why, when that is not obvious from the subject.
- Commits are authored by the user only, with no `Co-Authored-By` trailer, including commits an
  AI agent wrote.
- Work on `main`; never push without the owner's say-so.

## Starting a new app

```sh
~/dev/hudkit/scripts/hud-new-app.sh widgethud widgetHUD     # creates ~/dev/widgethud
cd ~/dev/widgethud
swift test && ./build.sh debug
WIDGETHUD_HOME=/tmp/widgethud-test WIDGETHUD_SOCKET=widgethud-test WIDGETHUD_NO_HOTKEYS=1 HUD_NO_ANNOUNCE=1 \
  build/widgetHUD.app/Contents/MacOS/widgetHUD --snapshot /tmp/widgethud.png
```

Then: pick the panel's symbol, `order` and hotkey (unused by siblings), draw the icon glyph
(`Icons/<repo>.svg`, then `hud-icon.sh`), replace `AppSettings` and
`say` with the real model and actions, and keep `docs/CONTRACT.md`, the README tables and the
manifest test in step as verbs and settings change. [AGENT-GUIDE.md](AGENT-GUIDE.md) walks
through all of it with a worked example and the verification sequence.

## Where the current apps differ

All seven apps have `Sources/<Product>/Resources`, the build/install shims, `VERSION`,
`CHANGELOG.md`, `ci.yml` and a `<Product>Tests` target. What differs from the rules above:

| App | Difference |
|---|---|
| sift | Kit is `FileKit` (Stash depends on it by that name); settings live in UserDefaults and `<home>/rules.json`, not `preferences.json`; reads `SIFT_TARGETS_FILE` and `SIFT_DOCKS_FILE` too |
| mechahud | an extra `MechaHUDCore` target; `MECHAHUD_DEFAULTS` (a defaults suite) read beside `MECHAHUD_HOME` |
| stash | `STASH_SOCKET` also takes an absolute path |
| scratch, sift, stash, ffmpeghud, magickhud, servershud | `--snapshot` keeps the app running after writing the PNG (Stash quits with `--snapshot-quit`); quit it with `<repo> quit` |
| all but the template and mechahud | the CLI ignores a leading `ctl` and has `watch` |

MacHUD itself (`machud`) is the umbrella app, not a panel app: it keeps its own bundle id
(`com.jrisberg.machud`), control socket (`/tmp/machud-<uid>.sock`, plus the contract socket
`machud`) and shell-script CLI (see its README). It builds and installs through the same shims
(`Sources/MacHUD/Resources`, `MacHUD.entitlements` for Apple Events), with
`scripts/install-hooks.sh` linking `machud`.
