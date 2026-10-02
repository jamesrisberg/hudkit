# Building a MacHUD app: the agent playbook

For an AI coding agent asked to "make me a MacHUD app that does X". Follow the steps in order;
every command here was run as written (macOS 26.6, Swift 6.4, HUDKit 0.3.0). The
spec behind it is [CONTRACT.md](CONTRACT.md); the CLI grammar is [CLI.md](CLI.md); repo rules
are [CONVENTIONS.md](CONVENTIONS.md).

The worked example builds **TallyHUD**: a hover panel with a counter that `tallyhud bump`
increments, that counts files dropped on its MacHUD dock button, with one setting, parking and
its menu hosted by MacHUD.
Replace `tallyhud` / `TallyHUD` / `TALLYHUD` with your app's names throughout.

Contents: [0 Decide](#0-decide) · [1 Prerequisites](#1-prerequisites) · [2 Scaffold](#2-scaffold) ·
[3 File map](#3-file-map) · [4 Worked example](#4-worked-example-tallyhud) ·
[5 Window behaviour](#5-window-behaviour-hover-or-windowed) · [6 Snapshots](#6-look-at-it-with---snapshot) ·
[7 Isolation](#7-isolation-never-disturb-the-user) · [8 Verify](#8-verify) ·
[9 Register with MacHUD](#9-register-with-a-running-machud) · [10 Pitfalls](#10-pitfalls) ·
[11 Definition of done](#11-definition-of-done)

## 0. Decide

Settle these before writing code; ask the user when the request does not say.

| Decision | Rule | Example |
|---|---|---|
| Repo name | lowercase letters and digits, starts with a letter; it is also the socket name, CLI name and bundle id suffix | `tallyhud` |
| Product | a Swift identifier; the displayed name and target prefix; lowercased it should equal the repo | `TallyHUD` |
| Panel kind | `hover`: a glance-and-go panel that drops out of the MacHUD dock while the pointer rests on its button (clipboard, notes, a converter). `windowed`: a working window the user clicks to open and keeps (a file browser, a dashboard). See [section 5](#5-window-behaviour-hover-or-windowed). Desktop widgets are extra panels next to these ([Widgets](#widgets)) | `hover` |
| Actions | the app's verbs, each `action <verb> k=v` over the socket and a CLI shorthand | `bump`, `reset` |
| Settings | what the user can change in MacHUD's settings window | `defaultStep` |
| File drops | does the dock button accept files? (`acceptsFileDrop`) | yes |
| Hotkey | one unused global hotkey. Taken: ⌃⌥Space, ⌃⌥D, ⌃⌥B (MacHUD), ⌃⌥N and ⌃⌥⇧V (Scratch), ⌃⌥V (Stash), ⌥/ (Sift), ⌃⌥F (ffmpegHUD), ⌃⌥I (magickHUD), ⌃⌥M (MechaHUD), ⌃⌥P (serversHUD) | ⌃⌥H (the template's) |
| Dock order | `order` in the manifest; family hover apps use 1-5 | `90` |

## 1. Prerequisites

```sh
sw_vers -productVersion          # 14.0 or later
swift --version                  # Swift 5.9 or later (Xcode or the command line tools)
ls ~/dev/hudkit/Package.swift    # HUDKit checked out; apps are created next to it
command -v nc machud             # nc ships with macOS; machud only if MacHUD is installed
```

Icons additionally need `rsvg-convert` and ImageMagick (`brew install librsvg imagemagick`).
The template ships a placeholder icon, so they are optional.

## 2. Scaffold

```sh
~/dev/hudkit/scripts/hud-new-app.sh tallyhud TallyHUD
cd ~/dev/tallyhud
swift test
HUD_NO_ANNOUNCE=1 ./build.sh debug
```

`hud-new-app.sh <repo> <Product> [parent-dir]` copies `Templates/App` to
`<parent-dir>/<repo>` (default: next to HUDKit, i.e. `~/dev`), fills the placeholders, installs
`.github/workflows/ci.yml`, runs `git init -b main` and commits `TallyHUD 0.1.0 from the HUDKit
app template`. It refuses an existing directory and a repo name that is not lowercase letters and
digits. The new app is complete and compliant before you change anything: it has one hover panel
`main` that shows a greeting, a `say` action, two settings and a CLI.

`Package.swift` depends on HUDKit at `../hudkit`, so the parent directory must contain `hudkit`.
For a throwaway app outside `~/dev`, link it first:

```sh
mkdir -p /tmp/hudapps && ln -sfn ~/dev/hudkit /tmp/hudapps/hudkit
~/dev/hudkit/scripts/hud-new-app.sh tallyhud TallyHUD /tmp/hudapps
```

`./build.sh [release|debug]` (default release) builds `build/TallyHUD.app` and prints its path
as the last line; see [CONVENTIONS.md](CONVENTIONS.md#build-and-install) for what it assembles.
Without `HUD_NO_ANNOUNCE=1` it also announces the bundle to the user's running MacHUD, which adds
a TallyHUD button to their dock at once. Keep `HUD_NO_ANNOUNCE=1` on every build and launch
until the user wants the app in their dock ([section 9](#9-register-with-a-running-machud)).

## 3. File map

| File | What it is | Edit when |
|---|---|---|
| `Sources/TallyHUDKit/*.swift` | the pure core: models, parsing, persistence. Foundation only, no AppKit | always: the app's logic goes here, with tests |
| `Sources/TallyHUDKit/AppSettings.swift` | the settings struct, validation (`applying`), `preferences.json` I/O | adding or changing a setting |
| `Sources/TallyHUD/main.swift` | starts `NSApplication` as an accessory (menu bar) app | never |
| `Sources/TallyHUD/AppDelegate.swift` | wiring, status item, hotkey, `--snapshot` | hotkey, menu items, `HUDEditMenu`, menu bar consolidation, launch flags |
| `Sources/TallyHUD/AppEnvironment.swift` | `TALLYHUD_HOME`, `TALLYHUD_SOCKET`, `TALLYHUD_NO_HOTKEYS` | new files under the home dir |
| `Sources/TallyHUD/AppModel.swift` | observable state the UI and the socket share (main actor) | new state |
| `Sources/TallyHUD/ControlHost.swift` | the `HUDPanelHost`: panels, states, actions, settings over the socket; `builtinManifest` | new actions, panels, modes |
| `Sources/TallyHUD/PanelController.swift` | the `HUDPanelWindow`, glass, show/hide animation, snapshot | window behaviour, size, modes |
| `Sources/TallyHUD/PanelView.swift` | the SwiftUI content | the UI |
| `Sources/TallyHUD/Resources/machud.json` | the manifest MacHUD reads | panels, verbs, capabilities, kind, order |
| `Sources/TallyHUD/Resources/settings.json` | the settings schema MacHUD's settings window renders | with every setting change |
| `Sources/TallyHUD/Resources/Info.plist` | bundle metadata; version fields are placeholders filled by `hud-build.sh` | rarely (never the version fields) |
| `Sources/TallyHUD/Resources/AppIcon.icns`, `MenuBarIcon*.png` | icons from `hud-icon.sh` | with a new glyph |
| `Sources/TallyHUDCLI/main.swift` | the `tallyhud` CLI: shorthands, then `HUDSocketClient.runCLI` | new shorthands |
| `Tests/TallyHUDKitTests/` | Kit unit tests | with every Kit change |
| `Tests/TallyHUDTests/ControlHostTests.swift` | drives `router.handle` directly (no socket) | with every action |
| `Tests/TallyHUDTests/ManifestTests.swift` | manifest = conventions, `builtinManifest` = file, schema keys = `AppSettings.keys`, Info.plist | if you change the panel `kind` |
| `docs/CONTRACT.md`, `README.md`, `CHANGELOG.md` | the app's own docs | with every verb, setting or flag |
| `VERSION` | the app version (`0.1.0`) | at a release |
| `build.sh`, `install.sh` | shims into `../hudkit/scripts` | never |

## 4. Worked example: TallyHUD

After `hud-new-app.sh tallyhud TallyHUD` (step 2), make these changes. Each file below is shown
whole; write it as shown.

### 4.1 The Kit type and its test

Logic that can be tested without a window goes in the Kit. Values arrive from the socket as
strings, so the Kit parses and validates them.

`Sources/TallyHUDKit/Tally.swift` (new):

```swift
import Foundation

/// The counter behind TallyHUD's panel. Pure (no AppKit), so it is unit-tested.
/// Values arrive from the socket as strings, so `bump(by:)` parses and validates them.
public struct Tally: Codable, Equatable, Sendable {
    public private(set) var count: Int

    public init(count: Int = 0) { self.count = count }

    public enum TallyError: Error, Equatable, CustomStringConvertible {
        case invalidStep(String)

        public var description: String {
            switch self {
            case .invalidStep(let raw): return "by must be a whole number, not \(raw)"
            }
        }
    }

    /// Adds `raw` (nil or empty means 1). Throws, changing nothing, when it is not a whole number.
    public mutating func bump(by raw: String? = nil) throws {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespaces)
        guard let step = trimmed.isEmpty ? 1 : Int(trimmed) else { throw TallyError.invalidStep(raw ?? "") }
        count += step
    }

    public mutating func reset() { count = 0 }
}
```

`Tests/TallyHUDKitTests/TallyTests.swift` (new):

```swift
import XCTest
@testable import TallyHUDKit

final class TallyTests: XCTestCase {
    func testBumpDefaultsToOne() throws {
        var tally = Tally()
        try tally.bump()
        try tally.bump(by: "")
        XCTAssertEqual(tally.count, 2)
    }

    func testBumpParsesTheStep() throws {
        var tally = Tally()
        try tally.bump(by: " 5 ")
        try tally.bump(by: "-2")
        XCTAssertEqual(tally.count, 3)
    }

    func testBadStepChangesNothing() {
        var tally = Tally(count: 4)
        XCTAssertThrowsError(try tally.bump(by: "lots")) {
            XCTAssertEqual($0 as? Tally.TallyError, .invalidStep("lots"))
        }
        XCTAssertEqual(tally.count, 4)
    }

    func testReset() throws {
        var tally = Tally(count: 9)
        tally.reset()
        XCTAssertEqual(tally, Tally())
    }
}
```

```sh
swift test --filter TallyTests
```

### 4.2 A setting

Adding a setting touches five places that tests keep in step: the `AppSettings` struct, its
`init(from:)`, its `applying(_:)` switch and `json`, `AppSettings.keys`, and `settings.json`.

Read every new field in `init(from:)` with `Self.value(c, .key, default:)`: the template merges
saved values over the defaults key by key, so a `preferences.json` written before the field
existed (or holding a value that does not decode) keeps the user's other settings.

`Sources/TallyHUDKit/AppSettings.swift` (replace):

```swift
import Foundation

/// TallyHUD's settings: the values behind Resources/settings.json, persisted as JSON in
/// `<home>/preferences.json`. Values arrive over the socket as strings (`settings set k=v`),
/// so `applying(_:)` parses and validates them all before changing anything.
public struct AppSettings: Codable, Equatable, Sendable {
    public var greeting: String
    public var showCount: Bool
    /// What `bump` adds when no `by=` is given.
    public var defaultStep: Int

    public init(greeting: String = AppSettings.defaultGreeting, showCount: Bool = true, defaultStep: Int = 1) {
        self.greeting = greeting
        self.showCount = showCount
        self.defaultStep = defaultStep
    }

    public static let defaultGreeting = "Hello from TallyHUD"
    /// The keys `settings get` reports and `settings set` accepts (Resources/settings.json).
    public static let keys: Set<String> = ["greeting", "showCount", "defaultStep"]

    /// Saved values are merged over the defaults key by key: a key missing from
    /// `preferences.json` (written before the setting existed) or one that does not decode
    /// keeps its default, and every other saved value is kept.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        greeting = Self.value(c, .greeting, default: d.greeting)
        showCount = Self.value(c, .showCount, default: d.showCount)
        defaultStep = Self.value(c, .defaultStep, default: d.defaultStep)
    }

    private static func value<T: Decodable, K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K, default fallback: T) -> T {
        ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    public enum SettingsError: Error, Equatable, CustomStringConvertible {
        case unknownKey(String)
        case invalid(key: String, value: String)

        public var description: String {
            switch self {
            case .unknownKey(let key): return "unknown setting \(key)"
            case .invalid(let key, let value): return "invalid value \(value) for \(key)"
            }
        }
    }

    /// The settings with `values` applied; throws on the first unknown key or bad value.
    public func applying(_ values: [String: String]) throws -> AppSettings {
        var next = self
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            switch key {
            case "greeting":
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw SettingsError.invalid(key: key, value: value) }
                next.greeting = trimmed
            case "showCount":
                guard let flag = Self.bool(value) else { throw SettingsError.invalid(key: key, value: value) }
                next.showCount = flag
            case "defaultStep":
                guard let step = Int(value.trimmingCharacters(in: .whitespaces)), step >= 1 else {
                    throw SettingsError.invalid(key: key, value: value)
                }
                next.defaultStep = step
            default:
                throw SettingsError.unknownKey(key)
            }
        }
        return next
    }

    /// `settings get`'s payload.
    public var json: [String: Any] { ["greeting": greeting, "showCount": showCount, "defaultStep": defaultStep] }

    static func bool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    // MARK: Persistence

    /// Reads the settings at `url`, saved values over the defaults (see `init(from:)`); defaults
    /// when the file is missing or not a JSON object.
    public static func load(from url: URL) -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
```

`Sources/TallyHUD/Resources/settings.json` (replace):

```json
{
  "version": 1,
  "settings": [
    {
      "key": "greeting",
      "title": "Greeting",
      "type": "string",
      "default": "Hello from TallyHUD",
      "help": "What the panel says until `tallyhud say` changes it."
    },
    {
      "key": "showCount",
      "title": "Show how many times the panel was opened",
      "type": "bool",
      "default": true
    },
    {
      "key": "defaultStep",
      "title": "Step",
      "type": "int",
      "default": 1,
      "help": "What `tallyhud bump` adds when no number is given (1 or more)."
    }
  ]
}
```

Append to `Tests/TallyHUDKitTests/AppSettingsTests.swift`:

```swift
final class DefaultStepTests: XCTestCase {
    func testDefaultStepValidates() throws {
        XCTAssertEqual(try AppSettings().applying(["defaultStep": "5"]).defaultStep, 5)
        XCTAssertThrowsError(try AppSettings().applying(["defaultStep": "0"]))
        XCTAssertThrowsError(try AppSettings().applying(["defaultStep": "two"]))
    }

    func testOldPreferencesKeepTheirValues() throws {
        let old = Data(#"{"greeting": "Yo", "showCount": false}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertEqual(settings, AppSettings(greeting: "Yo", showCount: false, defaultStep: 1))
    }
}
```

Schema types are `string`, `bool`, `int`, `number` (a decimal), `enum`, `path`; `int` and
`number` take `min`, `max` and `step`, and the router rejects a value outside them before
`applying` runs (validate in `applying` too: `swift run` and tests may bypass the schema). Never name a setting
`action`, `set`, `get`, `schema`, `key`, `value` or `_` (the router strips those).

### 4.3 The model

`AppModel` is the main-actor state the SwiftUI view observes and the host mutates.

`Sources/TallyHUD/AppModel.swift` (replace):

```swift
import Foundation
import TallyHUDKit

/// What the panel shows. Owns the settings and writes them under `AppEnvironment`'s home.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var settings: AppSettings
    /// Set by `tallyhud say`; the greeting until then.
    @Published var message: String?
    @Published private(set) var opens = 0
    /// The counter `tallyhud bump` / `reset` / file drops change.
    @Published private(set) var tally = Tally()

    let settingsURL: URL?

    /// `settingsURL` nil keeps everything in memory (tests).
    init(settingsURL: URL?) {
        self.settingsURL = settingsURL
        settings = settingsURL.map(AppSettings.load(from:)) ?? AppSettings()
    }

    var text: String { message ?? settings.greeting }

    func panelOpened() { opens += 1 }

    func updateSettings(_ values: [String: String]) throws {
        let next = try settings.applying(values)
        if let settingsURL { try next.save(to: settingsURL) }
        settings = next
    }

    /// Validates first, so a bad step leaves the count alone. No `by=`: the `defaultStep` setting.
    func bump(by raw: String?) throws {
        var next = tally
        try next.bump(by: raw ?? String(settings.defaultStep))
        tally = next
    }

    func resetTally() { tally.reset() }
}
```

### 4.4 The manifest

`Sources/TallyHUD/Resources/machud.json` (replace):

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

`verbs` must keep `"frame"` (without it MacHUD places the window through Accessibility instead of
`panel frame`). `capabilities: ["acceptsFileDrop"]` obliges the app to handle `action drop`
(4.5). `ControlHost.builtinManifest` must equal this file; `ManifestTests` checks it.

### 4.5 The host (HUDPanelHost)

`ControlHost` is where the contract meets the app. Only `panelStates`, `showPanel(_:)` and
`hidePanel(_:)` are required by `HUDPanelHost`; this host also implements the options variants
(MacHUD's `from=`/`to=`/`anchor=`/`reason=`), `panel frame`, `panel mode` (parking), settings and
actions. Rules it follows:

- every method runs on the main thread and returns quickly; `performAction` calls `done` exactly
  once, on every path;
- `check(id)` throws `HUDControlError.noSuchPanel` for an unknown panel id;
- state changes that do not come through `panel` call `router.publishState()`;
- errors are thrown as `HUDControlError` (`.invalid("why")` → `{"ok": false, "error": "why"}`)
  or answered as `["ok": false, "error": ...]` from `performAction`.

`Sources/TallyHUD/ControlHost.swift` (replace):

```swift
import AppKit
import HUDKit
import TallyHUDKit

/// TallyHUD's side of the MacHUD contract: serves the control socket at
/// `~/Library/Application Support/MacHUD/sockets/tallyhud.sock` through HUDKit's router.
/// See docs/CONTRACT.md for the verbs.
@MainActor
final class ControlHost: HUDPanelHost {
    nonisolated static let panelID = "main"
    static let actions = ["say", "bump", "reset", HUDDrop.action, "show", "hide", "toggle"]

    /// Used when running outside a bundle (`swift run`, tests); mirrors Resources/machud.json.
    static let builtinManifest = HUDManifest(id: "xyz.machud.tallyhud", name: "TallyHUD", socket: "tallyhud", panels: [
        HUDManifest.Panel(id: panelID, title: "TallyHUD", symbol: "number.circle",
                          defaultSize: HUDSize(PanelController.size),
                          capabilities: [HUDDrop.capability],
                          verbs: ["show", "hide", "toggle", "frame", "mode", "say", "bump", "reset", "drop"],
                          settingsSchema: "settings.json", kind: .hover, order: 90),
    ], iconName: "number.circle")

    let manifest: HUDManifest
    let server: HUDSocketServer
    private(set) var router: HUDControlRouter!
    let model: AppModel
    let panel: PanelController

    init(model: AppModel, panel: PanelController, socketPath: String? = nil) {
        self.model = model
        self.panel = panel
        manifest = HUDManifest.main ?? Self.builtinManifest
        server = HUDSocketServer(path: socketPath ?? HUDSocket.path(for: AppEnvironment.socketName(default: manifest.socket)),
                                 label: "tallyhud.socket")
        router = HUDControlRouter(host: self, server: server, manifest: manifest)
    }

    func start() {
        router.install()
        if !server.start() { NSLog("TallyHUD: control socket failed to start at %@", server.path) }
        panel.onStateChange = { [weak self] in self?.router.publishState() }
    }

    func stop() { server.stop() }

    // MARK: - HUDPanelHost

    var panelDescriptors: [HUDManifest.Panel] { manifest.panels }

    /// `badge` is the count (MacHUD shows it); `status` the text on the panel.
    var panelStates: [HUDPanelState] {
        [HUDPanelState(id: Self.panelID, visible: panel.isShown, mode: panel.mode, badge: String(model.tally.count), status: model.text)]
    }

    private func check(_ id: String) throws {
        guard id == Self.panelID else { throw HUDControlError.noSuchPanel(id) }
    }

    func showPanel(_ id: String) throws { try check(id); panel.show() }
    func hidePanel(_ id: String) throws { try check(id); panel.hide() }

    func showPanel(_ id: String, options: [String: String]) throws {
        try check(id)
        panel.show(HUDPanelTransition(options))
    }

    func hidePanel(_ id: String, options: [String: String]) throws {
        try check(id)
        panel.hide(HUDPanelTransition(options))
    }

    func setPanelFrame(_ id: String, frame: CGRect) throws {
        try check(id)
        guard frame.width >= 100, frame.height >= 60 else { throw HUDControlError.invalid("frame too small") }
        panel.setFrame(frame)
    }

    func setPanelMode(_ id: String, mode: HUDPanelMode) throws {
        try setPanelMode(id, mode: mode, options: HUDPanelModeOptions())
    }

    /// `parked` honours MacHUD's `edge=`/`peek=`; there is no compact form.
    func setPanelMode(_ id: String, mode: HUDPanelMode, options: HUDPanelModeOptions) throws {
        try check(id)
        guard mode != .compact else { throw HUDControlError.unsupported("compact mode") }
        panel.setMode(mode, options: options)
    }

    // MARK: Settings

    func settings() -> [String: Any] { model.settings.json }

    func updateSettings(_ values: [String: String]) throws {
        do {
            try model.updateSettings(values)
        } catch let error as AppSettings.SettingsError {
            throw HUDControlError.invalid(error.description)
        }
        router.publishState()
    }

    // MARK: Actions

    /// Runs on the main thread; answer with `done` exactly once, quickly. Hand slow work to a
    /// background queue and reply when it is accepted, not when it is finished.
    func performAction(_ name: String, args: [String: String], done: @escaping ([String: Any]) -> Void) {
        switch name {
        case "say":
            let text = (args["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            model.message = text.isEmpty ? nil : text
            router.publishState()
            done(["ok": true, "text": model.text])
        case "bump":
            do {
                try model.bump(by: args["by"])
            } catch {
                done(["ok": false, "error": "\(error)"])
                return
            }
            router.publishState()
            done(["ok": true, "count": model.tally.count])
        case "reset":
            model.resetTally()
            router.publishState()
            done(["ok": true, "count": model.tally.count])
        case HUDDrop.action:
            // Files dropped on the MacHUD dock button: count them.
            let urls = HUDDrop.urls(from: args)
            guard !urls.isEmpty else { done(["ok": false, "error": "drop needs paths="]); return }
            try? model.bump(by: String(urls.count))
            router.publishState()
            done(["ok": true, "count": model.tally.count, "files": urls.map(\.path)])
        case "show", "hide", "toggle":
            switch name {
            case "show": panel.show()
            case "hide": panel.hide()
            default: panel.toggle()
            }
            done(["ok": true, "visible": panel.isShown])
        default:
            done(["ok": false, "error": "unknown action \(name) (\(Self.actions.joined(separator: ", ")))"])
        }
    }

    func quit() { NSApp.terminate(nil) }
}
```

Append to `Tests/TallyHUDTests/ControlHostTests.swift` (the tests call `router.handle` directly;
no socket is opened):

```swift
@MainActor
final class TallyActionTests: XCTestCase {
    private var host: ControlHost!

    override func setUp() async throws {
        let model = AppModel(settingsURL: nil)
        host = ControlHost(model: model, panel: PanelController(model: model),
                           socketPath: NSTemporaryDirectory() + "unused-\(UUID().uuidString).sock")
    }

    private func call(_ verb: String, _ args: [String: String] = [:]) -> [String: Any] {
        var out: [String: Any] = [:]
        host.router.handle(verb, args: args) { out = $0 }
        return out
    }

    func testBumpResetAndBadge() {
        XCTAssertEqual(call("action", ["name": "bump"])["count"] as? Int, 1)
        XCTAssertEqual(call("action", ["_": "bump", "bump": "1", "by": "4"])["count"] as? Int, 5, "the CLI's bare-verb form")
        XCTAssertEqual(call("action", ["name": "bump", "by": "x"])["ok"] as? Bool, false)
        XCTAssertEqual((call("state")["panels"] as? [[String: Any]])?.first?["badge"] as? String, "5")
        XCTAssertEqual(call("action", ["name": "reset"])["count"] as? Int, 0)
    }

    func testDropCountsFiles() {
        let args = HUDDrop.args(for: [URL(fileURLWithPath: "/tmp/a b.txt"), URL(fileURLWithPath: "/tmp/c|d")])
        var payload = args
        payload["name"] = HUDDrop.action
        let reply = call("action", payload)
        XCTAssertEqual(reply["count"] as? Int, 2)
        XCTAssertEqual(reply["files"] as? [String], ["/tmp/a b.txt", "/tmp/c|d"])
    }
}
```

A slow action (a download, an ffmpeg run) must not hold the main thread. Reply when the work is
accepted and publish the result later:

```swift
case "convert":
    let input = args["path"] ?? ""
    DispatchQueue.global(qos: .userInitiated).async {
        let result = Converter.run(input)                  // a Kit function
        DispatchQueue.main.async { [weak self] in
            self?.model.lastResult = result
            self?.router.publishState()
        }
    }
    done(["ok": true, "accepted": input])
```

### 4.6 The panel UI

The panel is a `HUDPanelWindow` (the window recipe, see section 5) whose content view is a
`HUDGlassView` (Liquid Glass on macOS 26, a `.hudWindow` blur on earlier macOS) hosting the SwiftUI view.
The template's `PanelController` sets that up; a SwiftUI-only view can use `.hudGlass()` instead,
but the AppKit container is what lets `--snapshot` draw the content.

`Sources/TallyHUD/PanelView.swift` (replace):

```swift
import SwiftUI

/// The panel's content; `PanelController` puts it on HUD glass.
struct PanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            Text("\(model.tally.count)")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(model.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if model.settings.showCount {
                Text("Opened \(model.opens) time\(model.opens == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

Parking (`panel mode parked`) is optional; with it, MacHUD's loadouts and `machud park` park the
panel over the socket instead of through Accessibility. `Sources/TallyHUD/PanelController.swift`
(replace):

```swift
import AppKit
import HUDKit
import SwiftUI

/// Owns the hover panel: a non-activating `HUDPanelWindow` whose content is a `HUDGlassView`
/// (Liquid Glass on macOS 26) hosting the SwiftUI `PanelView`. (A SwiftUI-only panel can use
/// `.hudGlass()` instead; the AppKit container keeps `--snapshot` able to draw the content alone.)
/// MacHUD shows it from its dock button (`panel show from= anchor= reason=hover`) and hides it
/// when the pointer leaves (`panel hide to=`).
@MainActor
final class PanelController {
    static let size = CGSize(width: 320, height: 160)

    let model: AppModel
    let window: HUDPanelWindow
    private let glass = HUDGlassView(style: .panel)
    private let host: NSHostingView<PanelView>
    /// Whether the panel is meant to be on screen (`isVisible` stays true during a fade-out).
    private(set) var isShown = false
    /// `full`, or `parked` against a screen edge (`panel mode`).
    private(set) var mode: HUDPanelMode = .full
    /// Where a parked panel goes back to.
    private var restFrame: CGRect?
    /// Called when visibility changes (for `state` events).
    var onStateChange: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        window = HUDPanelWindow(contentRect: CGRect(origin: .zero, size: Self.size))
        window.title = "TallyHUD"
        host = NSHostingView(rootView: PanelView(model: model))
        glass.frame = CGRect(origin: .zero, size: Self.size)
        host.frame = glass.bounds
        host.autoresizingMask = [.width, .height]
        glass.addSubview(host)
        window.contentView = glass
        center()
    }

    /// Shows the panel. With MacHUD's `from=`/`anchor=` it slides out of the dock next to the
    /// button; otherwise it fades in where it is. Never takes focus: a hover panel must not
    /// steal the keyboard from the app the user is in.
    func show(_ transition: HUDPanelTransition = HUDPanelTransition()) {
        if mode == .parked { return setMode(.full) }
        if !isShown { model.panelOpened() }
        isShown = true
        if let from = transition.from {
            let frame = transition.panelFrame(size: window.frame.size) ?? window.frame
            HUDAnimation.slide(in: window, from: from, to: frame)
        } else {
            HUDAnimation.fadeIn(window)
        }
        onStateChange?()
    }

    /// Hides the panel, sliding toward `to=` (the dock) when given.
    func hide(_ transition: HUDPanelTransition = HUDPanelTransition()) {
        guard isShown else { return }
        isShown = false
        if let to = transition.to {
            HUDAnimation.slideOut(window, toward: to)
        } else {
            HUDAnimation.fadeOut(window)
        }
        onStateChange?()
    }

    func toggle() { isShown ? hide() : show() }

    /// `parked` slides the panel against `options.edge` (else the nearest edge) leaving a
    /// `peek`-point sliver (default 14); `full` slides it back. The panel stays "shown" while
    /// parked, so MacHUD sees it as visible.
    func setMode(_ newMode: HUDPanelMode, options: HUDPanelModeOptions = HUDPanelModeOptions()) {
        switch newMode {
        case .parked:
            guard mode != .parked else { return }
            restFrame = window.frame
            if !isShown {
                isShown = true
                window.alphaValue = 1
                window.orderFrontRegardless()
            }
            HUDParking.slideOut(window, edge: options.edge(for: window.frame), peek: options.peek ?? 14)
        case .full, .compact:
            if mode == .parked, let restFrame { HUDParking.slideIn(window, to: restFrame) }
            restFrame = nil
            isShown = true
        }
        mode = newMode == .parked ? .parked : .full
        onStateChange?()
    }

    func setFrame(_ frame: CGRect) { window.setFrame(frame, display: true) }

    private func center() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        window.setFrameOrigin(CGPoint(x: screen.midX - Self.size.width / 2, y: screen.midY - Self.size.height / 2))
    }

    /// `--snapshot <png>`: renders the panel's content over a dark stand-in for the glass (the
    /// real backdrop needs Screen Recording to capture), for docs and UI checks.
    func writeSnapshot(to url: URL) throws {
        let view: NSView = host
        let size = view.bounds.size
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let rect = CGRect(origin: .zero, size: size)
        let radius = HUDGlassView.Style.panel.cornerRadius
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
```

Style rules: dark appearance (the window recipe sets it), SF Symbols, system fonts, 16 pt
padding, secondary/tertiary foreground styles for detail text, no opaque backgrounds over the
glass. Glass styles: `.panel` (radius 20, 1 pt border, gloss) for floating panels, `.strip` for
edge strips, `.plain` for window content.

### 4.7 The CLI

The CLI maps shorthands onto the generic grammar and hands everything to
`HUDSocketClient.runCLI` ([CLI.md](CLI.md)).

`Sources/TallyHUDCLI/main.swift` (replace):

```swift
import Foundation
import HUDKit

// `tallyhud <command> [key=value ...]`: talks to TallyHUD's MacHUD control socket.
//
//   tallyhud hello
//   tallyhud bump            # +1
//   tallyhud bump 5          # +5 (same as `tallyhud action bump by=5`)
//   tallyhud reset
//   tallyhud say text="hi there"
//   tallyhud panel toggle id=main
//   tallyhud settings set showCount=0
//   tallyhud quit

let usage = """
usage: tallyhud <command> [key=value ...]
  hello | state | help | quit
  panel show|hide|toggle id=main
  panel frame id=main x= y= w= h=
  bump [n]                           add n (default 1) to the count
  reset                              set the count to 0
  say [text=]                        change what the panel says (empty: back to the greeting)
  action <verb> [k=v ...]            the long form (action bump by=2)
  settings get [key=]  |  settings set key=value ...

Environment: TALLYHUD_SOCKET picks the socket name (default tallyhud).

"""

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, !["-h", "--help"].contains(command) else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(arguments.isEmpty ? 2 : 0)
}

let socketName = ProcessInfo.processInfo.environment["TALLYHUD_SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? "tallyhud"

switch command {
case "say", "reset":
    // Shorthands for `action name=<verb> ...`.
    arguments = ["action", "name=\(command)"] + arguments.dropFirst()
case "bump":
    // `bump 5` is `action name=bump by=5`; `bump by=5` works too.
    let rest = arguments.dropFirst().map { $0.contains("=") ? $0 : "by=\($0)" }
    arguments = ["action", "name=bump"] + rest
case "settings" where arguments.count > 1 && ["get", "set"].contains(arguments[1]):
    // The sub-verb travels as `action=` so the router does not read a positional as a key.
    arguments[1] = "action=\(arguments[1])"
default:
    break
}

exit(HUDSocketClient.runCLI(path: HUDSocket.path(for: socketName), arguments: arguments, appName: "tallyhud"))
```

### 4.8 Menu bar consolidation

While MacHUD runs, it shows each app's status menu inside its own and the apps hide their menu
bar icons ([CONTRACT.md](CONTRACT.md#menu-bar-consolidation)). The template already wires it in
`Sources/TallyHUD/AppDelegate.swift`, `applicationDidFinishLaunching`; keep these lines after
`setupStatusItem()`:

```swift
        control.start()
        setupStatusItem()
        // Menu bar consolidation: MacHUD shows this menu inside its own (`menu`, `menu-invoke`)
        // and the icon hides while it does. The `menuBar.consumed` opt-out is kept in
        // <home>/menubar.json, so it follows TALLYHUD_HOME.
        control.router.menuProvider = { [weak self] in self?.statusItem.menu }
        HUDStatusItemPolicy.attach(statusItem, appID: control.manifest.id, store: .home(AppEnvironment.baseDirectory))
```

`tallyhud menu` lists the status menu and `hello` reports `statusItem`. The router adds the
`menuBar.consumed` setting (the user's opt-out) by itself. Menu items you add to the status
menu appear in MacHUD's menu with no further work.

### 4.9 Icon, hotkey, docs

- Icon: the family icons are SVGs in `~/dev/hudkit/Icons/<repo>.svg` (see `Icons/README.md`).
  Without one, `~/dev/hudkit/scripts/hud-icon.sh tallyhud .` renders the placeholder
  `Icons/template.svg` into `AppIcon.icns` and `MenuBarIcon.png`/`@2x`. Only draw a new glyph
  when the user asks; otherwise keep the template's placeholder files.
- Hotkey: `AppDelegate.toggleHotKey` (the template's ⌃⌥H). Pick one from section 0.
- Text input: the template calls `HUDEditMenu.install(appName: "TallyHUD")` first in
  `applicationDidFinishLaunching`; keep it: without it a panel's text fields and text views have no
  ⌘C/⌘V.
- Docs: update `docs/CONTRACT.md` (manifest summary, verbs table, settings, environment, launch
  flags), the README's tables, and `CHANGELOG.md`'s `[Unreleased]` section.

## 5. Window behaviour: hover or windowed

The manifest `kind` and the window's `HUDPanelWindow.Behavior` must agree
([CONTRACT.md](CONTRACT.md#behaviour-hover-and-windowed)).

| | `kind: hover` (template default) | `kind: windowed` |
|---|---|---|
| Use for | glance-and-go panels | working windows |
| Window | `HUDPanelWindow(contentRect:)` | `HUDPanelWindow(contentRect:behavior: .windowed)` |
| Level, Spaces | floating, every Space | normal, current Space, Mission Control, ⌘\` |
| Focus | never activates the app; `keyable: true` lets a click make it key for typing | activates the app; Dock tile and ⌘-Tab while shown (`HUDDockPolicy`) |
| MacHUD dock | shows on hover (60 ms), hides on leave (120 ms), click pins | click summons / dismisses |

To turn the worked example into a windowed app:

1. `machud.json`: `"kind": "windowed"`.
2. `ControlHost.builtinManifest`: `kind: .windowed`.
3. `Tests/TallyHUDTests/ManifestTests.swift`: `XCTAssertEqual(panel.kind, .windowed)`.
4. `PanelController.init`: `window = HUDPanelWindow(contentRect: CGRect(origin: .zero, size: Self.size), behavior: .windowed)`.
5. `PanelController.show(_:)`: add `window.activateOnShow(transition)` just before
   `onStateChange?()`. It orders the window in without focus for `reason=hover` and brings it
   forward and activates the app otherwise.

A hover panel with a text field: create the window with
`HUDPanelWindow(contentRect: ..., keyable: true)` and call `window.makeKey()` only for
`reason=click|summon` (`HUDPanelWindow.takesFocus(transition)`), never for `reason=hover`.

### Widgets

Any app may also serve desktop widgets: small glass tiles MacHUD places on the desktop
(under windows, raised by MacHUD's reveal) or floating above windows. Each widget type is one
more manifest panel and one `register` call; MacHUD creates, moves, resizes, configures and
removes the instances and gives them back after a relaunch. HUDKit owns the windows. The spec
is [CONTRACT.md § Widgets](CONTRACT.md#widgets). For TallyHUD, a widget showing the count:

1. `machud.json`, a second panel (the type's name is its `id`):

   ```json
   {"id": "count", "title": "Tally", "symbol": "number.circle", "kind": "widget",
    "widget": {"sizes": ["small", "medium"], "defaultSize": "small", "multiple": true}}
   ```

   Add `"settingsSchema": "count.widget.json"` inside `widget` for per-instance settings (a
   [settings schema](CONTRACT.md#settings-schema) file in `Resources`, separate from the app's
   `settings.json`).
2. `ControlHost.builtinManifest`, the same panel:
   `HUDManifest.Panel(id: "count", title: "Tally", symbol: "number.circle", kind: .widget, widget: HUDWidgetSpec(sizes: [.small, .medium]))`.
3. The view, given a `HUDWidgetContext` (instance, `size`, `settings` with `context["key"]`
   falling back to the schema's default, `isEditing`):

   ```swift
   struct CountWidget: View {
       @ObservedObject var model: AppModel
       @ObservedObject var context: HUDWidgetContext
       var body: some View {
           VStack(alignment: .leading) {
               Text("Tally").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
               Text("\(model.tally.count)").font(.system(size: context.size == .small ? 44 : 56, weight: .light, design: .rounded))
           }
           .foregroundStyle(.white)
           .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
           .padding(16)
       }
   }
   ```

4. `AppDelegate`, after `control` exists and **before** `control.start()` (MacHUD sends
   `widget sync` as soon as it connects):

   ```swift
   let widgets = HUDWidgetHost(manifest: control.manifest)
   widgets.register("count") { [model] in CountWidget(model: model!, context: $0) }
   widgets.onOpen = { [weak self] _ in self?.panel.show() }   // a click on the widget opens the panel
   control.router.widgetHost = widgets
   ```

   Keep `widgets` in a property. `register(_:keyable: true)` for a widget with a text field;
   widgets otherwise never take focus or activate the app.
5. A snapshot of the widget for the `--snapshot` path or a test:
   `try widgets.writeSnapshot(type: "count", size: .medium, to: url)`.
6. Check it over the isolated socket: `tallyhud widget create instance=a type=count frame=40,40,170,170`,
   `tallyhud widget edit on`, `tallyhud widget list`, `tallyhud widget remove instance=a`, and
   the widget block of the [compliance checklist](CONTRACT.md#compliance-checklist).

The widget needs MacHUD built on HUDKit 0.3 or later; an older MacHUD would offer a widget panel
as a windowed app.

## 6. Look at it with --snapshot

An agent cannot see the screen, and capturing the glass needs Screen Recording permission.
`--snapshot <path.png>` shows the panel, renders its content over a dark stand-in for the glass
after 1 s, prints the path and quits:

```sh
TALLYHUD_HOME=/tmp/tallyhud-test TALLYHUD_SOCKET=tallyhud-test TALLYHUD_NO_HOTKEYS=1 HUD_NO_ANNOUNCE=1 \
  build/TallyHUD.app/Contents/MacOS/TallyHUD --snapshot /tmp/tallyhud.png
```

Open `/tmp/tallyhud.png` with your image-reading tool (Claude Code: Read the file) and check
the layout: nothing clipped, text legible on dark, sizes as intended. The PNG is at the screen's
scale (640x320 for a 320x160 panel on Retina). The snapshot uses the settings in
`TALLYHUD_HOME`, so set them first (`settings set` against a running isolated instance) to
picture a particular state. Some apps add flags to pick what to picture (Scratch
`--snapshot-mode compact`, Sift `--snapshot-mode`, `--drawer`); add your own the same way in
`AppDelegate`.

## 7. Isolation: never disturb the user

The user's real apps and MacHUD are running. A test instance must not take their socket, their
settings or their hotkeys, nor show up in their dock:

| Variable | Read by | Effect |
|---|---|---|
| `TALLYHUD_HOME=/tmp/tallyhud-test` | the app | everything the app writes goes there (`preferences.json`, ...) |
| `TALLYHUD_SOCKET=tallyhud-test` | the app, the CLI | socket `~/Library/Application Support/MacHUD/sockets/tallyhud-test.sock` |
| `TALLYHUD_NO_HOTKEYS=1` | the app | no global hotkeys |
| `HUD_NO_ANNOUNCE=1` | HUDKit, `hud-build.sh` | the build and the launch do not announce the bundle to MacHUD |

Rules:

- Always set all four when you launch a build, including `--snapshot`, and `HUD_NO_ANNOUNCE=1`
  on `./build.sh`.
- Talk to your instance with the same `TALLYHUD_SOCKET` exported, or with `nc -U` on its path.
- Quit it with `quit`; never `pkill`/`killall` by name (that hits the user's copy too).
- `menuBar.consumed` lives in `<TALLYHUD_HOME>/menubar.json` on a test instance (the template
  attaches `HUDStatusItemPolicy` with `store: .home(AppEnvironment.baseDirectory)`), so setting it
  there leaves the user's copy alone.
- If a build was announced by mistake: `machud apps forget path=$PWD/build/TallyHUD.app`.
- Never quit, relaunch or `./install.sh` over the user's running apps or MacHUD without being
  asked. `./install.sh` replaces `/Applications/TallyHUD.app` and relaunches it.
- Never launch MacHUD's binary (`MacHUD.app/Contents/MacOS/MacHUD`) to "check" anything: it has
  no `--help`; it starts a second full MacHUD. Use `machud --help` (the shell script) and
  section 9 for an isolated MacHUD.

## 8. Verify

Run from the repo, in order. Each step's expected result is in the comment.

```sh
cd ~/dev/tallyhud
export TALLYHUD_HOME=/tmp/tallyhud-test TALLYHUD_SOCKET=tallyhud-test TALLYHUD_NO_HOTKEYS=1 HUD_NO_ANNOUNCE=1
swift test > /tmp/tallyhud-swifttest.txt 2>&1; echo "swift test exit $?"   # exit 0
grep -E "Executed [0-9]+ tests, with [0-9]+ failures" /tmp/tallyhud-swifttest.txt | tail -2   # "with 0 failures"
./build.sh debug                                                           # last line: .../build/TallyHUD.app

build/TallyHUD.app/Contents/MacOS/TallyHUD --snapshot /tmp/tallyhud.png    # prints /tmp/tallyhud.png; now look at it
build/TallyHUD.app/Contents/MacOS/TallyHUD > /tmp/tallyhud-test.log 2>&1 &
CLI=build/TallyHUD.app/Contents/Helpers/tallyhud
for i in {1..50}; do $CLI hello > /dev/null 2>&1 && break; sleep 0.2; done
$CLI hello                       # "ok": true, "hudkit": "0.3.0", "app": "xyz.machud.tallyhud", "version": "0.1.0"
$CLI panel show id=main          # "visible": true
$CLI state                       # panels[0]: "id": "main", "visible": true, "badge": "0"
$CLI bump 2                      # "count": 2
$CLI action drop "paths=/tmp/a%20b.txt|/tmp/c.txt"   # "count": 4, "files": [...]
$CLI menu                        # "items": [{"id": "0", "title": "Show/Hide TallyHUD", ...}, ...]
$CLI panel hide id=main          # "visible": false
```

Then run the [compliance checklist](CONTRACT.md#compliance-checklist): set

```sh
SOCK="$HOME/Library/Application Support/MacHUD/sockets/tallyhud-test.sock"; PANEL=main
```

and paste its two blocks (the second checks `menu` and `drop` and ends with `quit`); every line
must print `PASS`. Finish with:

```sh
cat /tmp/tallyhud-test.log       # empty, or only system noise; no "control socket failed to start"
unset TALLYHUD_HOME TALLYHUD_SOCKET TALLYHUD_NO_HOTKEYS HUD_NO_ANNOUNCE
rm -rf /tmp/tallyhud-test
```

If `hello` never answers, read `/tmp/tallyhud-test.log`: `control socket failed to start` means
another process serves that socket name or the path is too long.

## 9. Register with a running MacHUD

MacHUD finds an app by the `machud.json` in its bundle: in `/Applications`, `~/Applications`, the
`apps.searchPaths` directories, or because the bundle was **announced** (`hud-build.sh` after a
build, the app itself at launch; [CONTRACT.md](CONTRACT.md#launch-announcement)). It talks to the
socket the manifest names, so the app must run **without** `TALLYHUD_SOCKET` for MacHUD to reach
it. The first two routes change the user's setup: ask before using them.

**Install** (the normal route for a finished app):

```sh
./install.sh             # release build → /Applications/TallyHUD.app, CLI linked onto PATH, launched
machud apps              # xyz.machud.tallyhud "health": "running"
machud panel show id=xyz.machud.tallyhud/main
```

**A dev build in the user's MacHUD**: build without `HUD_NO_ANNOUNCE`. `./build.sh debug` prints
`Announced to MacHUD`, the button appears in their dock, and `machud apps` lists the bundle
(`known`). When an installed copy declares the same id, the running one wins, else the newest.
Undo with `machud apps forget path=$PWD/build/TallyHUD.app`.

**An isolated MacHUD** (for testing; touches nothing of the user's): its own socket, config and
host file, no hotkeys, no standard directories and no tool dock on screen. With `MACHUD_SOCKET`
exported, the build and the app announce themselves to it instead of the user's MacHUD.

```sh
mkdir -p /tmp/machud-tallyhud-test
cat > /tmp/machud-tallyhud-test/layouts.json <<'EOF'
{"layouts": [], "loadouts": [], "toolDock": {"enabled": false}, "apps": {"standardDirectories": false}}
EOF
export MACHUD_SOCKET=/tmp/machud-tallyhud-test.sock MACHUD_CONFIG=/tmp/machud-tallyhud-test/layouts.json MACHUD_NO_HOTKEYS=1
/Applications/MacHUD.app/Contents/MacOS/MacHUD > /tmp/machud-tallyhud-test/machud.log 2>&1 &
for i in {1..50}; do machud ping > /dev/null 2>&1 && break; sleep 0.2; done
./build.sh debug                                   # "Announced to MacHUD" (the isolated one)
TALLYHUD_HOME=/tmp/tallyhud-test TALLYHUD_NO_HOTKEYS=1 build/TallyHUD.app/Contents/MacOS/TallyHUD > /dev/null 2>&1 &
sleep 2
machud apps                                        # xyz.machud.tallyhud "health": "running", "known": [".../build/TallyHUD.app"]
machud panel show id=xyz.machud.tallyhud/main      # "visible": true
machud apps menu id=TallyHUD                       # the app's status menu, as MacHUD hosts it
machud tooldock drop id=TallyHUD paths=/tmp/a.txt,/tmp/b.txt
machud apps quit id=TallyHUD                       # "wasRunning": true
machud quit
unset MACHUD_SOCKET MACHUD_CONFIG MACHUD_NO_HOTKEYS
sleep 1; rm -rf /tmp/machud-tallyhud-test /tmp/tallyhud-test
```

`machud` sends every command to the instance `MACHUD_SOCKET` names; with it unset it talks to the
user's MacHUD again. Never set `MACHUD_SOCKET` to `/tmp/machud-$(id -u).sock` (the live one).

## 10. Pitfalls

| Pitfall | What happens | Do instead |
|---|---|---|
| Socket path over 103 bytes (a long `<REPO>_SOCKET`, an absolute path under `$TMPDIR`) | bind fails, the app runs without a socket, the CLI says `socket path too long (<n> bytes, the limit is 103): <path>` | short socket names; sockets live in `~/Library/Application Support/MacHUD/sockets` |
| Naming the CLI product or a file `Contents/MacOS/<repo>` | on a case-insensitive volume `tallyhud` and `TallyHUD` are the same file | keep the template: CLI target `<Product>CLI`, shipped as `Contents/Helpers/<repo>` |
| Activating or making key on a hover show | the user's typing goes to your panel while they only moved the pointer | never `NSApp.activate`/`makeKey` for `reason=hover`; use `activateOnShow(transition)` |
| Slow work in a handler | the main thread blocks, the UI freezes, MacHUD's hover cross-fade waits; after 90 s `timeout` | reply at once, work on a background queue, `publishState()` when done |
| `performAction` path that never calls `done` | the caller hangs 90 s, then `timeout` | every `switch` branch ends in `done(...)` |
| No `HUDEditMenu.install` | ⌘C/⌘V/⌘A beep in text fields of a menu bar app | install it at launch in any app with text input |
| Editing Info.plist version fields | ignored: `hud-build.sh` overwrites `CFBundleShortVersionString` (from `VERSION`) and `CFBundleVersion` (commit count) | change `VERSION` |
| Removing `LSUIElement` or changing `CFBundleExecutable` | a Dock icon for a menu bar app / a bundle that does not launch | leave them; `ManifestTests.testInfoPlist` checks them |
| `builtinManifest` out of step with `machud.json` | `testBuiltinManifestMirrorsTheFile` fails; `swift run` serves a different manifest | edit both together |
| `socket` in the manifest ≠ repo name | `hud-build.sh` names the CLI after `socket`; conventions and tests break | `socket` = repo = CLI |
| `acceptsFileDrop` without an `action drop` handler | every drop on the dock button fails (`unknown action drop`) | handle `HUDDrop.action` with `HUDDrop.urls(from:)` |
| `verbs` without `"frame"` | MacHUD stops sending `panel frame` and moves the window by Accessibility | keep `"frame"` in `verbs` (or leave `verbs` empty) |
| State changed by a hotkey/menu/action without `publishState()` | MacHUD's dock dot and hover logic go stale | publish on every change outside `panel` |
| New `AppSettings` field not read in `init(from:)` | it never loads from `preferences.json` (always its default) | add `Self.value(c, .key, default:)` for it (4.2) |
| Sending JSON `true` or numbers as args | they arrive as `"1"`, `"3"` | send strings |
| Launching a build without the isolation variables | it collides with the user's installed copy (socket refused, hotkey taken, settings shared) | section 7 |
| Building or launching without `HUD_NO_ANNOUNCE=1` | the build is announced to the user's MacHUD and its button appears in their dock | `HUD_NO_ANNOUNCE=1`; undo with `machud apps forget path=<.app>` |
| A setting named `menuBar.consumed` | the router owns that key once `HUDStatusItemPolicy` is attached | pick another key |
| `pkill TallyHUD` | kills the user's copy too | `quit` over the socket |
| `swift test` output ends with "0 tests in 0 suites" | that is the swift-testing runner; XCTest results are above it | grep `Executed ... with 0 failures` and check the exit status |
| Unquoted shell values | `text=a b` is two arguments; `|` in `paths=` pipes | quote: `text="a b"`, `"paths=/a|/b"` |
| Scaffolding into a directory without `hudkit` beside it | `swift test` fails to resolve `../hudkit` | scaffold next to HUDKit or symlink it (section 2) |

## 11. Definition of done

- [ ] `swift test` exits 0; every new Kit type and action has tests.
- [ ] `./build.sh debug` succeeds; `build/<Product>.app/Contents/Helpers/<repo>` exists.
- [ ] `--snapshot` PNG inspected and the UI looks right.
- [ ] Isolated instance: `hello`, `panel show`, `state`, every action, `panel hide`, and the full
      compliance checklist all pass; `quit` removes the socket.
- [ ] `machud.json` and `builtinManifest` agree; `kind` matches the window behaviour; `verbs`
      lists the actions and keeps `frame`; `acceptsFileDrop` only with a `drop` handler.
- [ ] `settings.json` has every key in `AppSettings.keys`, with a `default` and a `help` line.
- [ ] Hover panels never take focus on `reason=hover`; windowed ones use `activateOnShow`.
- [ ] Every `kind: widget` panel has a registered view, `router.widgetHost` is set before the
      socket starts, and a widget snapshot was inspected.
- [ ] `HUDEditMenu.install` if there is any text input; hotkey unused by siblings.
- [ ] `router.menuProvider` set and `HUDStatusItemPolicy` attached; `<repo> menu` lists the menu.
- [ ] CLI `--help` lists every shorthand; `docs/CONTRACT.md`, README tables and `CHANGELOG.md`
      describe every verb, setting and flag.
- [ ] Commits: one logical change each, on `main`, the agent trailer; **not pushed** without the
      user's say-so ([CONVENTIONS.md](CONVENTIONS.md#commits)).
- [ ] Nothing of the user's was quit, installed over, announced to or reconfigured without
      asking; test instances are quit and `/tmp` test directories removed.
