# Changelog

All notable changes to HUDKit are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions are the contract version
`hello` reports as `hudkit` (`HUDKit.version`, kept equal to [VERSION](VERSION)). While HUDKit
is 0.x a contract addition bumps the minor version and additive API or fixes the patch.

## [Unreleased]

## [0.2.0] - 2026-09-29

### Added
- `HUDNotchGeometry`: pure frame math for a panel anchored under the notch, or hanging from the
  menu bar (or the bare screen edge in full screen) on a screen without one.
- `HUDPanelWindow.anchorUnderNotch(size:on:)` and `.notchAnchorLevel`: places a panel at that
  frame, raised to `.statusBar` so it draws above the menu bar layer.
- `HUDFullscreenObserver`, `HUDScreenSnapshot` and `HUDWindowSnapshot`: publishes per-screen
  whether the frontmost app is full screen there, from positive window evidence (a layer-0
  window owned by the frontmost app sized to the screen's full frame), for a host to hide or
  fall back a notch-anchored panel.
- `HUDNotchGeometry.bodyPath(width:height:bottomRadius:)`: the notch-body shape a host draws
  extending the camera housing downward (square top corners, rounded bottom corners), so every
  app that needs the look shares one copy instead of porting it by hand.
- A socket request's `args` can now carry an object or array value (`args: {"settings": {…}}`):
  it arrives at the handler as that value's JSON text instead of Swift's plain description, so a
  client can send structured settings over the socket and the handler decodes real JSON. A
  string value is unaffected either way.
- `agent-sessions` manifest capability: a panel that shows agent sessions answers `action
  name=open-session id=<sessionKey>` and a `sessions` command, so a client can ask "who shows
  agent sessions" instead of naming an app. `HUDAgentSessions` and `HUDAgentSession` (see
  `docs/CONTRACT.md` § Agent sessions).
- `text-feed` manifest capability: a panel that keeps a history of finished text answers a `feed
  action=add text= source= [title=] [date=]` command, so a client can send it text (a dictation
  transcript, an agent reply, ...) without naming an app or writing to the clipboard.
  `HUDTextFeed` (see `docs/CONTRACT.md` § Text feed).

**BrainKit** (its own package in this repo: `.package(path: "../hudkit/Kits/BrainKit")`)
- A local agent brain for any app: Codex, Claude Code, Hermes or mclaude (a mechaclaude session)
  behind a Node.js companion (Node 22 or later, no npm packages) that ships inside BrainKit with
  its tests.
- `BrainService` finds Node.js, launches and supervises the companion from a plain
  `BrainServiceConfiguration` (runtime, workspace, state directory, port, tool paths, assistant
  name), restarts it with backoff, stops it with the app, and hands out `AgentSessionClient`s.
  A change of runtime alone keeps the companion running and switches it once no turn is running,
  so a host only reconfigures.
- `BrainSettings`, the Codable brain choice and per-runtime options a settings tab binds to.
- `AgentSessionClient` (turns, approvals, cancel, reset, runtime switch, folder permissions),
  `TranscriptModel` for rendering a conversation, `ManagedService`, `ExecutableLocator` and
  `BrainCatalog`.
- The companion's `--assistant-name` names the assistant in its voice instructions; without it
  the instructions name none. Its environment variables use the `BRAINKIT_` prefix.
- BrainKit: the brain can run as an mclaude (mechaclaude) session that also appears in MechaHUD;
  snapshots name the session (`sessionKey`).
- BrainKit: a host can give its brain tools (`toolServers`, stdio MCP servers) and a description
  of its world (`hostContext`); Codex, Claude Code and mclaude use them, Hermes reports it cannot.

**Build**
- `hud-build.sh` builds the executable products named in `HUD_HELPERS` and ships each in
  `Contents/Helpers`, signed with the app's entitlements before the app, for an app that runs a
  helper process of its own (MacHUD's voice host). Each helper finds the SwiftPM resource bundles
  through links beside it.
- `hud-build.sh` copies every `@rpath` framework the app or a helper links (such as
  `Sparkle.framework`) into `Contents/Frameworks` and signs it, so the bundle loads it at runtime.
- `hud-release.sh` builds a sibling path package at the remote branch its checkout tracks (else
  `origin/main`), and a `../hudkit/Kits/<Kit>` package from HUDKit at `HUDKIT_REF`.

**VoiceKit** (a separate package in `Kits/VoiceKit`; apps that depend only on HUDKit do not
fetch or build it)
- Wake word detection on the Mac with openWakeWord models, fed by the app's own microphone
  audio (`WakeListener`, `InProcessWakeDetector`, `OpenWakeWordEngine`). Wake models download
  only when asked; "Hey Jarvis" is for personal, non-commercial use and is never bundled.
- Trigger phrases: a list of phrases, each mapped to an action, matched from a wake model or
  from the start of a transcript ("Hey Computer" starts an agent turn).
- Reply voices behind one protocol: Kokoro on the Mac, the Mac's system voices, and Grok
  (xAI's cloud voice), with the system voice as the fallback, and sentence-by-sentence speech
  of a reply as it streams in (`SpeechStreamer`).
- Spoken replies read cleanly: markdown formatting (headings, emphasis, list markers, links) is
  stripped before a sentence is spoken, inline code is read as plain words, and fenced code
  blocks are skipped entirely instead of being read aloud.
- Kokoro and Grok both synthesize the next sentence while the current one plays, so a reply
  spoken sentence by sentence has no gap, and no flicker in the "speaking" indicator, between
  sentences.
- `VoiceSettings`: wake word on/off, phrase and sensitivity, reply voice, spoken replies (off by
  default) and each voice's options; the Grok key is kept in the Keychain, not in settings.
- Verified model downloads (`ModelStore`): pinned sizes and checksums, reuse of identical files
  another app already downloaded, and a one-time check of a complete folder installed elsewhere.

### Fixed
- `hud-build.sh` copies every SwiftPM resource bundle (`.build/<configuration>/*.bundle`) into
  `Contents/Resources` before signing, so an app using BrainKit's companion or VoiceKit's Kokoro
  voice has the bundle it needs at first use.

## [0.1.0] - 2026-09-27

The shared contract, visual language and build tooling for MacHUD apps, contract version 0.1.

### Added

**Socket**
- `HUDSocket`, `HUDSocketServer` and `HUDSocketClient`: JSON lines over a Unix socket in
  `~/Library/Application Support/MacHUD/sockets` (dir 0700, socket 0600), one request per
  connection, `subscribe` streams with `HUDSubscription`, a built-in `help`. A server serves
  additional paths with the same handlers, refuses to take over a socket another live process
  is serving and removes its socket files when the app terminates.
- `HUDSocketClient.runCLI`, the app CLIs' shared grammar, output and exit codes; a socket path
  over 103 bytes is reported as `socket path too long (<n> bytes, the limit is 103): <path>`.
- Launch announcement: `HUDSocketServer.start()` in an app whose bundle has a
  `Contents/Resources/machud.json` sends `apps announce path=<bundle>` to a running MacHUD
  (`MACHUD_SOCKET`, else `HUDSocket.path(for: "machud")`), once per process, on a background
  queue, ignoring every error; `HUD_NO_ANNOUNCE=1` turns it off. `HUDAnnounce` exposes the
  pieces (`machudSocketPath`, `skipReason`, `announce`).

**Manifest**
- `HUDManifest` (`machud.json`: id, name, socket, `iconName`, panels with `kind` `hover` or
  `windowed`, `order`, `symbol`, `defaultSize`, capabilities, verbs, `settingsSchema`),
  tolerant of unknown `kind` values; `HUDManifest.dockSorted`.
- `HUDManifestScanner`: directories, then single bundles (`bundles:`);
  `scanReport(keepingDuplicates:)` returns every bundle declaring an id, so MacHUD can choose
  between a dev build and an installed copy.

**Contract**
- `HUDPanelHost` and `HUDControlRouter`, serving the required verbs `hello`, `panel
  show|hide|toggle|frame|mode`, `state`, `subscribe`, `settings get|set|schema`, `action` and
  `quit`. `hello` reports `hudkit` (the contract version) and `version` (the app's
  `CFBundleShortVersionString`, `HUDControlRouter.appVersion`). The router publishes a `state`
  event after every `panel` command.
- Directional show and hide for the MacHUD tool dock: `panel show|toggle from= anchor= reason=`,
  `panel hide to=`, `HUDPanelTransition` and `showPanel/hidePanel/togglePanel(_:options:)`
  (defaulting to the plain variants). `panel mode parked` takes `edge=` and `peek=`
  (`setPanelMode(_:mode:options:)`).
- Actions as `action name=` or the bare verb (`action append`); file drops as `action drop
  paths=` (`HUDDrop`, percent-encoded paths) for panels with the `acceptsFileDrop` capability.
- Optional verbs `menu` and `menu-invoke id= [title=]` (`HUDControlRouter.optionalVerbs`, served
  once `router.menuProvider` is set).

**Settings**
- `HUDSettingsSchema`, the format MacHUD's settings window renders and `settings schema` serves:
  types `string`, `bool`, `int`, `number` (a decimal; aliases `double`, `float`, `decimal`),
  `enum` and `path`, and the keys `min`, `max` (inclusive bounds for `int` and `number`) and
  `step` (the stepper increment). `Field.parse` and `schema.validate(values)` check values;
  `HUDSettingValue.doubleValue`.
- `settings set` validates every value its host's `settingsSchema` describes (type, enum
  options, bounds) before calling `updateSettings`, all or nothing; keys the schema does not
  list are the host's to judge.

**Chrome and motion**
- `HUDGlassView` / `HUDGlass` / `.hudGlass()` (Liquid Glass on macOS 26, a `.hudWindow` blur
  elsewhere; styles `.panel`, `.strip`, `.plain`) and `HUDGlossView`.
- `HUDPanelWindow` with `Behavior` `.hover` (borderless, non-activating, floating, all Spaces,
  draggable by its background, frames unconstrained so panels can park past the top edge) and
  `.windowed` (the same glass as a normal window); `applyHUDRecipe(behavior:level:)`;
  `activateOnShow(_:)`. `HUDDockPolicy` gives a menu bar app a Dock tile while one of its
  windowed panels is on screen.
- `HUDSpring` and `HUDAnimation` (`reveal`/`conceal`, `slide(in:from:to:duration:)`,
  `slideOut(_:toward:duration:)`; a fade-in that interrupts a fade-out wins), `HUDParking`
  (edge parking with a visible sliver) and `HUDEdge`.
- `HUDEditMenu`: a hidden main menu so ⌘C/⌘V/⌘X/⌘A/⌘Z work in a menu bar app's text fields.

**Dock**
- `HUDDockPosition` (eight snap positions with sector snapping), `HUDDockLayout` (edge and L
  geometry, `avoiding(frame:others:along:in:)`, `panelFrame(dockFrames:)` so hover panels clear
  every arm of an L).
- `HUDDockRegistry`: `docks.json` with locked atomic writes and a debounced watch.
- `HUDDockStripView` and its SwiftUI wrapper `HUDDockStrip`: the MacHUD tool dock's strip
  (`HUDDockTile` items with badges and states, hover magnification and labels, indicator dots,
  file drops with spring loading, click versus drag at a 4 pt threshold, snapping reported
  through `HUDDockStripDelegate`, `writeSnapshot(to:)` without Screen Recording);
  `HUDDockStyle` and `HUDDockPlacement` hold its measurements and run/L geometry.

**Menu bar**
- `HUDHotKey` and `HUDHotKeyCenter`: global hotkeys.
- `HUDStatusIcon.image(fallbackSymbol:accessibilityDescription:)`: the bundled
  `MenuBarIcon.png` as a template image, or an SF Symbol.
- Menu bar consolidation: `HUDMenuBridge` (serializes an `NSMenu` with index-path ids and
  performs an item by id), `HUDMenuHost` (MacHUD's `host.json`, honouring `MACHUD_HOST_FILE`)
  and `HUDStatusItemPolicy.attach(_:appID:store:)`, which hides an app's status item while a
  live MacHUD hosts menus and shows it again when MacHUD quits, crashes or turns the feature
  off. The per-app `menuBar.consumed` opt-out is kept in a `Store` (`.home(<data directory>)`,
  `.file(_:)`, `.defaults(_:)`) and served by `settings get|set|schema`; `hello` reports
  `statusItem`.

**Scripts and template**
- `scripts/hud-build.sh` (bundle, sign with `--timestamp` for a Developer ID identity, announce
  the build to a running MacHUD), `hud-install.sh` (install to `/Applications`, link the CLI,
  relaunch; repo hooks in `scripts/install-hooks.sh`), `hud-new-app.sh` (a new app repo from
  `Templates/App`), `hud-release.sh` (a signed, notarized, stapled GitHub release and its
  catalog entry; in HUDKit, the tag and release notes), `hud-catalog.sh` (MacHUD's app
  catalog) and `hud-icon.sh` (renders `Icons/<repo>.svg` into `AppIcon.icns` and the menu bar
  PNGs).
- `scripts/hud-ci.yml`, the CI workflow every app repo shares.
- `Templates/App`: a minimal complete, compliant app (one hover panel, settings merged over the
  defaults key by key, menu bar consolidation, `HUDEditMenu`, placeholder icon, CLI, tests).
- Family icons: `Icons/<repo>.svg` for MacHUD and the seven panel apps and `Icons/template.svg`.

**Docs**
- `docs/CONTRACT.md` (the canonical MacHUD app contract with a compliance checklist),
  `docs/AGENT-GUIDE.md` (the playbook, with the TallyHUD worked example), `docs/CLI.md`,
  `docs/CONVENTIONS.md` (the app repo layout, versions, releasing, icons), `llms.txt` and the
  Claude Code skill `.claude/skills/hudkit-app`.
