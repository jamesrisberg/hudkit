# BrainKit

BrainKit gives a macOS app a local agent "brain": Codex, Claude Code, Hermes or a runtime
plugin the user installed, reached through a small Node service (the companion) that the app launches, supervises and talks to
over loopback HTTP. It is its own Swift package in the HUDKit repository (`Kits/BrainKit`); an app that
depends only on HUDKit does not fetch or build it.

```swift
.package(path: "../hudkit/Kits/BrainKit")
.product(name: "BrainKit", package: "BrainKit")
```

BrainKit depends on Foundation, Combine and CryptoKit only. The companion needs Node.js 22 or
later on the user's Mac and no npm packages.

## Pieces

| Type | What it does |
|---|---|
| `BrainService` | Builds the companion's command line from a `BrainServiceConfiguration`, finds Node.js, runs it under a `ManagedService`, reads its token and hands out clients |
| `BrainServiceConfiguration` | Runtime, workspace (`--cwd`), state directory, port, the Node/Codex/Claude/Hermes/assistant-name options, plugin executable overrides, tool servers and host context |
| `BrainToolServer`, `AgentToolServerStatus` | A stdio MCP server whose tools the agent gets; the snapshot's report of them |
| `BrainSettings` | The Codable brain choice and per-runtime options a settings tab binds to; `serviceConfiguration(stateDirectory:port:)` turns it into a configuration |
| `AgentSessionClient` | Polls complete snapshots and sends turns, approvals, cancel, reset, runtime switches and permissions |
| `AgentSessionSnapshot` and friends | `AgentRuntime` (a runtime id: `.codex`, `.hermes`, `.claude` or a plugin's), `AgentPermissions`, `AgentCapabilities`, `AgentApproval`, `AgentRoute`, `AgentTiming`, `AgentSessionError` |
| `TranscriptModel` | Reduces snapshots plus what the user said into transcript rows (user, reply, progress, approval, notice) and events (`turnStarted`, `firstOutput`, `approvalAdded`, `turnEnded`) |
| `ManagedService` | Keeps one child process running: readiness line, exponential backoff (1 s doubling to 30 s), gives up after 6 failed starts, 45 s readiness timeout, failures reset after 60 s up; a replaced process exits before its successor starts (at most 10 s wait); a failure's reason is the child's last output line |
| `ExecutableLocator`, `BrainCatalog` | Find `node`, `codex`, `claude`, `hermes` and plugins' tools the way a login shell would; install and sign-in commands per brain; Hermes API server detection; `detectAll` for the built-ins and every plugin |
| `RuntimePlugin` | A runtime plugin's folder as found: its `runtime.json`, or why it is refused |
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
<port> [--codex <path>] [--claude <path>] [--runtime-plugin <id>=<folder> --runtime-executable <id>=<path>]...
[--runtime-url <url>] [--assistant-name <name>]
[--tool-servers <state>/tool-servers.json] [--host-context <state>/host-context.md] --runtime <runtime>` in the workspace, with the tools' folders first on `PATH` and
`BRAINKIT_PARENT_PIPE=1`. The supervisor holds the child's stdin open; the companion exits
when it closes, so it never outlives the app, even after a crash. It is ready when it prints
`Brain companion ready at` (`BrainService.readinessMarker`).

- **Changes.** The first `configure` applies at once; later ones apply after 0.4 s without
  another change (`debounce`), so a host can pass every settings edit straight through.
  `stop()` (or `configure(nil)`) applies at once and drops a pending change.
- **Runtime switches.** A configuration that differs only in `runtime` keeps the running
  process, and `BrainService` switches it (`POST /v1/runtime`) once no turn is running,
  checking again every second while one is; the companion keeps each runtime's conversation.
  Each time the companion becomes ready the service also checks that it runs the configured
  runtime, so a change made while it was starting is not lost. The host only reconfigures.
  Any other change restarts the process once the old one has
  exited, so the port is free, including a change to the tool servers or host context.
  `restart()` restarts now and clears the failure count.
- **Tool servers and host context.** `toolServers` are stdio MCP servers (`name`, `command`,
  `arguments`, `environment`, `requireApproval`) whose tools the agent gets; `hostContext` is
  Markdown about the host's world, appended to the runtime's instructions after the voice
  instructions. They are written to `tool-servers.json` and `host-context.md` (0600) in the
  state directory, and removed when empty. Codex, Claude and plugins that take them use the
  servers; Hermes cannot, and `AgentSessionSnapshot.toolServers` says so in `note`. A server with
  `requireApproval` false runs its tools without asking; the agent's other actions keep their
  approval policy. Per-runtime details are in the companion README.
- **Endpoint.** `endpoint()` and `makeClient()` return nil until the process reports ready.
  The token must be a private (0600), regular, user-owned file of 64 hex digits, as the
  companion itself requires; a symlink is refused.
- **State directory.** Private (0700, applied to an existing directory too): the 256-bit `token` file (0600), `session.json` with the
  conversation ids, recent request ids and the folder permissions, and the host's
  `tool-servers.json` and `host-context.md` when given. The companion refuses a
  state directory that belongs to another workspace; `stateDirectory(forWorkspace:under:)`
  derives one per workspace from a hash of its canonical path.
- **Port.** The host chooses a loopback port (1024-65535). Two apps running a brain at the same
  time need different ports.
- **Why it cannot run.** Missing workspace, a relative state directory, a bad port, an
  assistant name that is not one line of at most 64 characters (UTF-16 units, the companion's
  rule), a tool server without a valid unique name or a command, a host context over 65,536
  characters, a missing companion, no Node.js 22+ or a chosen plugin that is not available
  (`Detection.unavailableReason`) leave `service.state` at `.unavailable(reason)`
  with a sentence to show; `nodeStatus` says which Node.js is used. `node --version` runs on
  the main actor, at most 2 s, once per path; `refreshDetections()` checks again after an
  install or upgrade.
- **Brains.** `detections` lists the built-in runtimes and every runtime plugin, by
  `AgentRuntime`: each one's `title`, `executable` (nil when not installed), install and login
  commands, `summary`, `docsURL`, a plugin's `note` and `missingRequirements`, and `refusal`;
  `isAvailable` and `unavailableReason` sum them up. Hermes' also says whether its API server
  is enabled in `~/.hermes/.env`. The companion
  reports what the running runtime can honour in `capabilities`; show or hide approvals, folder
  scope, model routing and cancel from it.
- **Runtime plugins.** A plugin is a folder `~/Library/Application Support/BrainKit/Runtimes/<id>/`
  (`BRAINKIT_RUNTIMES_DIR` names another parent folder; `ExecutableLocator.runtimesDirectory`)
  with a `runtime.json` and an adapter module; the companion README's "Runtime plugins" has the
  contract and the trust rule. `BrainService` passes every available plugin to the companion
  (`--runtime-plugin`, `--runtime-executable`), so switching to one needs no restart; a plugin
  that is refused, missing its executable or missing a tool it `requires` is not passed.
- **External sessions.** A runtime that drives a session another app also shows reports it in
  `AgentSessionSnapshot.sessionKey`, in the runtime's own form, so a host can ask that app to
  open it. Turns started there appear in the snapshots without a `requestId`.

## Settings

`BrainSettings` encodes as:

```json
{ "runtime": "codex", "workspacePath": "/Users/me/Assistant", "assistantName": "",
  "nodePath": "", "codex": { "executablePath": "" }, "claude": { "executablePath": "" },
  "hermes": { "url": "" }, "plugins": { "example-agent": { "executablePath": "" } } }
```

Empty paths are found on `PATH` and the common install folders (Homebrew, `~/.local/bin`,
nvm, Volta, `~/.claude/local`), and a plugin's also in its `searchPaths`. `plugins` holds each
runtime plugin's options by id. A missing key or a runtime that is not a valid id decodes to its
default; a valid id of a plugin that is not installed stays chosen and the service says why it
cannot run.
There are no secrets in it: Hermes' API key stays in `~/.hermes/.env` (or
`BRAINKIT_RUNTIME_TOKEN` in the companion's environment) and the companion token stays in the
state directory. The folder permissions (`approvedFolders` or `fullAccess`) are the companion's
own state, changed with `AgentSessionClient.setPermissions(_:)` while idle.

## The companion

The companion lives in `Sources/BrainKit/Companion` and ships in the target's resource bundle,
`BrainKit_BrainKit.bundle` (folder `Companion`), with its Node tests. `BrainCompanion.directory`
finds it in the app's `Contents/Resources`, next to the executable or test bundle (`swift run`,
`swift test`), then in the source checkout. `hud-build.sh` copies it into `Contents/Resources`
along with every other SwiftPM resource bundle (see `docs/CONVENTIONS.md`), so an app that ships
BrainKit needs nothing extra.

Its HTTP contract, the runtime interface, each brain's transport and approvals, and the voice
instructions are documented in [Companion/README.md](Sources/BrainKit/Companion/README.md).
Names the companion uses:

| Name | Meaning |
|---|---|
| `BRAINKIT_PARENT_PIPE=1` | exit when stdin reaches end-of-file |
| `BRAINKIT_RUNTIME_TOKEN` | Hermes API key when no `--runtime-token-file` is given |
| `BRAINKIT_APPROVAL_SOCKET`, `BRAINKIT_APPROVAL_TOKEN` | Claude Code's permission bridge (set by the companion) |
| `brainkit_permissions` | the permission MCP server Claude Code launches (`mcp__brainkit_permissions__approve`) |
| `brainkit-<uuid>` | Hermes session ids the companion creates |
| `--assistant-name NAME` | the name the voice instructions give the assistant; none by default |
| `--tool-servers`, `--host-context` | the host's tool servers and context, files in the state directory |
| `--runtime-plugin`, `--runtime-executable` | a runtime plugin's folder and the executable found for it |
| `BRAINKIT_RUNTIMES_DIR` | the folder runtime plugins are read from, instead of `~/Library/Application Support/BrainKit/Runtimes` |
| `~/.brainkit-companion` | default state directory when the companion is run by hand |

## Tests

From `Kits/BrainKit`:

```sh
swift build && swift test                                           # Swift side, plus a live turn
(cd Sources/BrainKit/Companion && node --test test/*.test.mjs)      # companion
```

No test starts a real agent CLI. The Swift tests drive the supervisor, launcher and client
against fakes; `BrainCompanionLiveTests` launches the companion from the built resource bundle
with real Node.js and the companion's Codex stand-in (`test/fixtures/fake-codex.mjs`),
completes one turn through `AgentSessionClient`, and checks the process ends on `stop()`. It is
skipped when Node.js 22 or later is not installed. The companion's `npm run smoke` and
`npm run acceptance*` scripts do use the installed Codex and are run by hand only.
