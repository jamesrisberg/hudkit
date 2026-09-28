# BrainKit

BrainKit gives a macOS app a local agent "brain": Codex, Claude Code or Hermes, reached
through a small Node service (the companion) that the app launches, supervises and talks to
over loopback HTTP. It is a separate product of this package; an app that imports only HUDKit
does not build it.

```swift
.package(path: "../hudkit")
.product(name: "BrainKit", package: "hudkit")
```

BrainKit depends on Foundation, Combine and CryptoKit only. The companion needs Node.js 22 or
later on the user's Mac and no npm packages.

## Pieces

| Type | What it does |
|---|---|
| `BrainService` | Builds the companion's command line from a `BrainServiceConfiguration`, finds Node.js, runs it under a `ManagedService`, reads its token and hands out clients |
| `BrainServiceConfiguration` | Runtime, workspace (`--cwd`), state directory, port, and the Node/Codex/Claude/Hermes/assistant-name options |
| `BrainSettings` | The Codable brain choice and per-runtime options a settings tab binds to; `serviceConfiguration(stateDirectory:port:)` turns it into a configuration |
| `AgentSessionClient` | Polls complete snapshots and sends turns, approvals, cancel, reset, runtime switches and permissions |
| `AgentSessionSnapshot` and friends | `AgentRuntime`, `AgentPermissions`, `AgentCapabilities`, `AgentApproval`, `AgentRoute`, `AgentTiming`, `AgentSessionError` |
| `TranscriptModel` | Reduces snapshots plus what the user said into transcript rows (user, reply, progress, approval, notice) and events (`turnStarted`, `firstOutput`, `approvalAdded`, `turnEnded`) |
| `ManagedService` | Keeps one child process running: readiness line, exponential backoff (1 s doubling to 30 s), gives up after 6 failed starts, 45 s readiness timeout, failures reset after 60 s up; a replaced process exits before its successor starts (at most 10 s wait); a failure's reason is the child's last output line |
| `ExecutableLocator`, `BrainCatalog` | Find `node`, `codex`, `claude`, `hermes` the way a login shell would; install and sign-in commands per brain; Hermes API server detection |
| `BrainCompanion` | Locates the bundled companion folder |

## Running a brain

```swift
import BrainKit

@MainActor final class Brain {
    let service = BrainService()
    var client: AgentSessionClient?

    func start(_ settings: BrainSettings) {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MyApp/brain")
        let state = BrainServiceConfiguration.stateDirectory(forWorkspace: settings.workspacePath, under: support)
        service.service.onReady = { [weak self] in
            guard let self, let client = self.service.makeClient() else { return }
            self.client = client
            Task { try? await client.connect() }
        }
        service.configure(settings.serviceConfiguration(stateDirectory: state.path, port: 8791))
    }
}
```

`BrainService` runs `node <Companion>/server.mjs --cwd <workspace> --state-dir <state> --port
<port> [--codex <path>] [--claude <path>] [--runtime-url <url>] [--assistant-name <name>]
--runtime <runtime>` in the workspace, with the tools' folders first on `PATH` and
`BRAINKIT_PARENT_PIPE=1`. The supervisor holds the child's stdin open; the companion exits
when it closes, so it never outlives the app, even after a crash. It is ready when it prints
`Brain companion ready at` (`BrainService.readinessMarker`).

- **Changes.** The first `configure` applies at once; later ones apply after 0.4 s without
  another change (`debounce`), so a host can pass every settings edit straight through.
  `stop()` (or `configure(nil)`) applies at once and drops a pending change.
- **Runtime switches.** A configuration that differs only in `runtime` keeps the running
  process; switch with `AgentSessionClient.setRuntime(_:)` (the companion keeps each
  runtime's conversation). Any other change restarts the process once the old one has
  exited, so the port is free. `restart()` restarts now and clears the failure count.
- **Endpoint.** `endpoint()` and `makeClient()` return nil until the process reports ready.
  The token must be a private (0600), regular, user-owned file of 64 hex digits, as the
  companion itself requires; a symlink is refused.
- **State directory.** Private (0700, applied to an existing directory too): the 256-bit `token` file (0600), `session.json` with the
  conversation ids, recent request ids and the folder permissions. The companion refuses a
  state directory that belongs to another workspace; `stateDirectory(forWorkspace:under:)`
  derives one per workspace from a hash of its canonical path.
- **Port.** The host chooses a loopback port (1024-65535). Two apps running a brain at the same
  time need different ports.
- **Why it cannot run.** Missing workspace, a relative state directory, a bad port, an
  assistant name that is not one line of at most 64 characters (UTF-16 units, the companion's
  rule), a missing companion or no Node.js 22+ leave `service.state` at `.unavailable(reason)`
  with a sentence to show; `nodeStatus` says which Node.js is used. `node --version` runs on
  the main actor, at most 2 s, once per path; `refreshDetections()` checks again after an
  install or upgrade.
- **Brains.** `detections` lists which of `codex`, `claude` and `hermes` are installed (and
  whether Hermes' API server is enabled in `~/.hermes/.env`). The companion reports what the
  running runtime can honour in `capabilities`; show or hide approvals, folder scope, model
  routing and cancel from it.

## Settings

`BrainSettings` encodes as:

```json
{ "runtime": "codex", "workspacePath": "/Users/me/Assistant", "assistantName": "",
  "nodePath": "", "codex": { "executablePath": "" }, "claude": { "executablePath": "" },
  "hermes": { "url": "" } }
```

Empty paths are found on `PATH` and the common install folders (Homebrew, `~/.local/bin`,
nvm, Volta, `~/.claude/local`). A missing key or an unknown runtime decodes to its default.
There are no secrets in it: Hermes' API key stays in `~/.hermes/.env` (or
`BRAINKIT_RUNTIME_TOKEN` in the companion's environment) and the companion token stays in the
state directory. The folder permissions (`approvedFolders` or `fullAccess`) are the companion's
own state, changed with `AgentSessionClient.setPermissions(_:)` while idle.

## The companion

The companion lives in `Sources/BrainKit/Companion` and ships in the target's resource bundle,
`HUDKit_BrainKit.bundle` (folder `Companion`), with its Node tests. `BrainCompanion.directory`
finds it in the app's `Contents/Resources`, next to the executable or test bundle (`swift run`,
`swift test`), then in the source checkout. `hud-build.sh` does not copy SwiftPM resource
bundles, so an app that ships BrainKit copies `.build/<configuration>/HUDKit_BrainKit.bundle`
into `Contents/Resources` itself.

Its HTTP contract, the runtime interface, each brain's transport and approvals, and the voice
instructions are documented in [Companion/README.md](../Sources/BrainKit/Companion/README.md).
Names the companion uses:

| Name | Meaning |
|---|---|
| `BRAINKIT_PARENT_PIPE=1` | exit when stdin reaches end-of-file |
| `BRAINKIT_RUNTIME_TOKEN` | Hermes API key when no `--runtime-token-file` is given |
| `BRAINKIT_APPROVAL_SOCKET`, `BRAINKIT_APPROVAL_TOKEN` | Claude Code's permission bridge (set by the companion) |
| `brainkit_permissions` | the permission MCP server Claude Code launches (`mcp__brainkit_permissions__approve`) |
| `brainkit-<uuid>` | Hermes session ids the companion creates |
| `--assistant-name NAME` | the name the voice instructions give the assistant; none by default |
| `~/.brainkit-companion` | default state directory when the companion is run by hand |

## Tests

```sh
swift test --filter BrainKitTests                                   # Swift side, plus a live turn
(cd Sources/BrainKit/Companion && node --test test/*.test.mjs)      # companion
```

No test starts a real agent CLI. The Swift tests drive the supervisor, launcher and client
against fakes; `BrainCompanionLiveTests` launches the companion from the built resource bundle
with real Node.js and the companion's Codex stand-in (`test/fixtures/fake-codex.mjs`),
completes one turn through `AgentSessionClient`, and checks the process ends on `stop()`. It is
skipped when Node.js 22 or later is not installed. The companion's `npm run smoke` and
`npm run acceptance*` scripts do use the installed Codex and are run by hand only.
