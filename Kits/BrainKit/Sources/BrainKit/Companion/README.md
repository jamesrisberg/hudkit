# Brain companion

This Node process connects a macOS host app to a tool-capable agent runtime (the
"brain"). It ships inside BrainKit as a resource (`Companion/` in the
`BrainKit_BrainKit.bundle`), and a host app runs it through BrainKit's `BrainService`:
`node server.mjs --cwd <workspace> --runtime <choice> --state-dir <private state> --port <port>`,
restarting it with backoff and reading the token file directly (see
[BrainKit's README](../../../README.md)). Running it by hand, as below, is the
manual mode. Audio stays in the host app's local speech pipeline; this service
accepts only text. The runtime sends that text and relevant tool context to its
configured model provider and keeps its own conversation history on disk.

Three runtimes are built in, and runtime plugins add others (see Runtime plugins):

| `--runtime` | Agent | Transport | Folder scope | Approvals | Cancel |
|---|---|---|---|---|---|
| `codex` (default) | Codex CLI | `codex app-server`, stdio JSON-RPC | enforced by Codex's sandbox | per command/patch | yes |
| `hermes` | Hermes Agent | `hermes gateway` API server, HTTP + SSE | advisory (Hermes' own config) | if the gateway advertises them | if advertised |
| `claude` | Claude Code CLI | `claude -p` stream-json, one process per turn | working dirs + permission mode | per tool call, MCP bridge | SIGINT |

The companion needs only Node.js 22 or later: no npm install, built-in modules only.

## Run

Choose a dedicated folder for the assistant's files and run from this directory:

```sh
mkdir -p "$HOME/AssistantWorkspace"
node server.mjs --cwd "$HOME/AssistantWorkspace"                    # Codex
node server.mjs --cwd "$HOME/AssistantWorkspace" --runtime hermes   # Hermes
node server.mjs --cwd "$HOME/AssistantWorkspace" --runtime claude   # Claude Code
```

Flags:

- `--cwd /absolute/path` (required) — the workspace. Never chosen over HTTP.
- `--runtime codex|hermes|claude|<plugin id>` — without it, the runtime last chosen (by
  flag or by the app) is read from the state directory; the first default is `codex`, and
  a saved plugin the command line no longer names falls back to it.
- `--state-dir /absolute/path` — private state (default `~/.brainkit-companion`).
- `--port 8789` — HTTP port on 127.0.0.1 (default 8788).
- `--codex /path/to/codex`, `--claude /path/to/claude` —
  executables if not on PATH
  (Homebrew Codex: `--codex /opt/homebrew/bin/codex`).
- `--runtime-url http://127.0.0.1:8642` — Hermes API server. Plain HTTP only on
  loopback; https elsewhere. Persisted in the state directory.
- `--runtime-token-file /path` (mode 0600) or `--runtime-token TOKEN` — Hermes
  `API_SERVER_KEY`. Prefer the file: arguments are visible in `ps`. The token is also
  read from `BRAINKIT_RUNTIME_TOKEN`, and otherwise from `API_SERVER_KEY` in
  `$HERMES_HOME/.env` (default `~/.hermes/.env`); the token is never persisted.
- `--assistant-name NAME` — the name the voice instructions give the assistant (one
  line, at most 64 characters). Without it the instructions name none.
- `--tool-servers /path/tool-servers.json` (mode 0600) — stdio MCP servers whose tools the
  agent gets; see Tool servers and host context.
- `--host-context /path/host-context.md` (mode 0600) — Markdown describing the host app's
  world, appended to the voice instructions (at most 65,536 characters).
- `--runtime-plugin <id>=/absolute/plugin/folder` (repeatable) — a runtime plugin; see Runtime
  plugins. `--runtime-executable <id>=/absolute/path` (repeatable, one per plugin) is the
  executable found for it; without one the adapter receives `runtime.json`'s `executable`
  name as given.

Keep the terminal running; the companion does not install a launch agent. A host
app connects to `http://127.0.0.1:8788` with the 256-bit token the companion creates
with mode 0600 in `<state dir>/token` (`~/.brainkit-companion/token` by default).

With `BRAINKIT_PARENT_PIPE=1` in the environment (`BrainService` sets it) the companion
exits when its stdin reaches end-of-file, so it never outlives the app, and SIGTERM
still stops it promptly.

A saved state directory belongs to one workspace; a different workspace needs a
different `--state-dir`. Only run one companion per state directory. If the chosen
runtime cannot start (Hermes not running, CLI missing), the companion stays up and
reports `status: "failed"` with the reason; the app retries with Check Connection or
switches runtime. Unsafe saved permissions (an approved folder replaced by a
symlink) remain fatal at startup.

To stop, press Control-C. If a runtime process exits or a protocol mutation times
out, the companion reports failure and does not retry the operation; `POST
/v1/runtime` with the same runtime (the app's Check Connection) restarts it and
resumes the saved conversation. A lost HTTP response never means an action did not
execute: inspect the current session before repeating it. App disconnection alone
does not cancel an agent turn. New conversation resets the conversation only while
idle; the old history remains in the runtime's own store.

### Tool servers and host context

A host app can give its brain tools and a description of its world. `BrainService` writes
both into the state directory (`tool-servers.json`, `host-context.md`, mode 0600) and passes
them with `--tool-servers` and `--host-context`; the companion reads them once at start
(a change restarts it) and refuses files that are not private, user-owned regular files.
`tool-servers.json` is an array of stdio MCP servers:

```json
[{ "name": "machud", "command": "/Applications/MacHUD.app/Contents/Helpers/machud-mcp",
   "arguments": [], "environment": { "MACHUD_SOCKET": "/tmp/machud.sock" }, "requireApproval": false }]
```

Names are letters, digits, `_` and `-` (at most 64, `brainkit_permissions` is reserved);
unknown keys, duplicate names and non-string arguments or environment values are refused
(`tool-servers.mjs`). How each runtime gets them:

| Runtime | Tool servers | `requireApproval: false` | `requireApproval: true` |
|---|---|---|---|
| `codex` | `codex app-server -c mcp_servers.<name>.command="…" -c mcp_servers.<name>.args=[…] [-c mcp_servers.<name>.env={ "K" = "v" }]` (values are TOML) | `-c mcp_servers.<name>.default_tools_approval_mode="approve"`: no prompt | `…="prompt"`: every call asks (an `mcpServer/elicitation/request` with `_meta.codex_approval_kind: "mcp_tool_call"`, shown as a `tool` approval; Allow answers `{"action":"accept","content":{}}`, Deny `{"action":"decline"}`) |
| `claude` | added to `--mcp-config` (`mcpServers`, `type: "stdio"`) | `--allowedTools mcp__<name>__*` | Claude Code's normal permission prompt |
| `hermes` | not supported | | |
| a plugin | as its adapter passes them (`supportsToolServers`) | | |

Only elicitations from a configured tool server that are tool-call approvals become
approvals; any other elicitation is refused, which Codex treats as a decline. The host
context is appended, after a blank line, to the instructions every runtime receives:
Codex's `developerInstructions`, Claude Code's `--append-system-prompt`, Hermes' run
`instructions`, and a plugin's `start` options. Snapshots report the servers as `toolServers: { names, active,
note }`; with Hermes `active` is false and `note` says Hermes cannot use them (Hermes only has
the tools configured in Hermes itself).
The Codex form was checked against Codex 0.155.1: with these overrides `config/read` shows the
servers with their environment and approval mode, and `mcpServerStatus/list` lists a
configured stdio server's tools, without a model turn.

### Codex

Install Codex CLI and sign in with `codex login`. Available models and configured
tools/skills come from the user's installed Codex setup; the companion chooses a
model per request (see Voice model routing). Approved folders (the default) use
workspace-write, network disabled, on-request approval, and the human reviewer.
File changes within these folders may execute without prompting. This is a write
boundary: Codex can still read files outside these folders. Protected metadata and
network operations may still prompt. Full access uses danger-full-access with
approval policy never; commands can change any files your macOS account permits.
macOS privacy controls still apply. Policy changes require an idle session and are
applied explicitly to every turn, including turns resumed after restart. The app
offers grant-once or deny for actual shell/file permission requests; unrecognized
interactive runtime requests fail closed. Cancel waits for Codex's completion
notification before displaying interruption.

### Hermes

Hermes Agent keeps its own configuration (provider, tools, memory, approvals) in
`~/.hermes`, set up with `hermes setup`. Enable its API server in `~/.hermes/.env`
and start the gateway:

```sh
# ~/.hermes/.env
API_SERVER_ENABLED=true
API_SERVER_KEY=<a long random secret>
```

```sh
hermes gateway
```

The companion reads `API_SERVER_KEY`/`API_SERVER_PORT` from that file when no token or
URL is given. At start it calls `GET /v1/capabilities` and requires the Runs API
(`run_submission`, `run_events_sse`). Each turn is `POST /v1/runs` with the
conversation's `session_id`, the voice instructions as `instructions`, and an
`Idempotency-Key` derived from the app's request ID (Hermes deduplicates it
durably, so an uncertain POST cannot start a second run). `GET /v1/runs/{id}/events`
streams `message.delta` (spoken output), `tool.*`/`subagent.*`/`message.interim`
(progress), `approval.request`, and the terminal `run.completed|failed|cancelled|interrupted`.
If the stream drops, the companion polls `GET /v1/runs/{id}`. New conversation
creates a new `session_id`; after a restart the last run is shown, never resubmitted.

Approvals: `approval.request` becomes an app approval; Allow sends
`{"choice":"once","request_id":…}` and Deny sends `"deny"` to
`POST /v1/runs/{id}/approval`. The session/always scopes Hermes offers are never
sent. When the gateway does not advertise approvals (`run_approval_response`,
`approval_events`, or the documented `run_approval`), approval requests are denied
automatically and `capabilities.approvals` is false; without `run_stop`, cancel
returns 409. Hermes executes tools on its own host under its own approval settings
(`approvals.mode` in `~/.hermes/config.yaml`), so approved folders are advisory
(`capabilities.folderScope` is false) and the workspace is only suggested to the
agent in its instructions. Reference:
[Hermes API server docs](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/api-server.md).

### Claude Code

Install Claude Code and sign in by running `claude` once. Each turn runs

```
claude -p --input-format stream-json --output-format stream-json --verbose --include-partial-messages
       (--session-id <new uuid> | --resume <uuid>) --append-system-prompt <voice instructions>
       --permission-mode acceptEdits|bypassPermissions [--add-dir <approved folder>...]
       --mcp-config <bridge + tool servers> [--allowedTools mcp__<server>__*...]
       --permission-prompt-tool mcp__brainkit_permissions__approve
```

in the workspace. Approved folders map to `acceptEdits` with the extra folders as
`--add-dir`: edits inside them run without asking, anything else that needs
permission (most shell commands, writes elsewhere) asks. Full access maps to
`bypassPermissions`. Claude Code otherwise loads the user's normal settings,
CLAUDE.md, MCP servers and skills.

Permission prompts go to `runtimes/claude-permission-mcp.mjs`, a zero-dependency
MCP stdio server that Claude Code launches. It forwards each request over a Unix
socket in a private (0700) temporary directory, authenticated with a per-process
token passed only in the environment, and returns
`{"behavior":"allow","updatedInput":<original input>}` or
`{"behavior":"deny","message":…}`. Allow is always this one call; no permission rule
is saved. Cancel sends SIGINT, which ends and records the turn (the next turn
resumes the conversation), then SIGTERM after five seconds. Voice answers to
approvals need a working directory, so Claude and Hermes approvals are answered on
screen (Allow Once / Deny). References: [headless mode](https://code.claude.com/docs/en/headless),
[CLI reference](https://code.claude.com/docs/en/cli-reference).

## Runtime interface

`runtimes/Runtime.mjs` is the contract; read its header comment for the exact
semantics. `session.mjs` owns everything that must behave the same for every
runtime — request-ID deduplication and receipts, permission validation and
persistence, opaque approval IDs, timing, the snapshot — and talks to one runtime:

| Method | Purpose |
|---|---|
| `start(cwd, { saved, permissions, instructions })` → `{ threadId, lastTurn }` | connect, create or resume a conversation |
| `submit(text, { requestId, permissions, beforeSend })` → `{ turnId }` | start exactly one turn; await `beforeSend({ route })` immediately before dispatch |
| `approve(id, 'accept' \| 'decline')` | answer one approval the runtime emitted |
| `setPermissions(permissions)` | apply the validated scope from the next turn at the latest |
| `cancel(turnId)` | request interruption; confirmation arrives as an event |
| `reset({ permissions })` → `{ threadId }` | new conversation (idle only) |
| `snapshot()` → `{ routing, sessionKey }` | runtime-specific snapshot fields; `sessionKey` names an external session, or null |
| `persistentState()` | extra JSON saved in the state directory, returned as `saved` |
| `capabilities` | `{ approvals, folderScope, modelRouting, cancel }` |
| `supportsToolServers` | whether the runtime gives the agent the `toolServers` its constructor received |
| `close()` | release processes and connections |

Events: `started {turnId}`, `output {turnId, text}` (the full visible text so far),
`progress {turnId, text}`, `approval {id, turnId, kind, reason, command, cwd}`,
`approvalResolved {id}` (answered in another client), `completed|failed|cancelled
{turnId, output, error}`, `notice {error}`, and `disconnected Error`. `started` while
idle is a turn another client of the same session began; it carries no request ID. A
runtime refuses requests it cannot represent (fail closed) and declines its own pending
approvals when a turn ends.

### Adding a runtime

1. Create `runtimes/<id>.mjs` exporting a class that extends `Runtime` with
   `static id = '<id>'` and `static displayName`, implementing the table above.
   Never retry a turn internally; use the runtime's own idempotency key if it has one.
2. Register it in `runtimes/index.mjs` (`RUNTIMES` and `createRuntime`, which maps
   companion options such as `--runtime-url` to its constructor).
3. Report honest `capabilities`; the app hides or explains what is missing.
4. Add `test/<id>.test.mjs` driving it through `Session` against a fake of the
   runtime's transport (see `test/hermes.test.mjs`, `test/claude.test.mjs`).
5. In BrainKit, add the case to `AgentRuntime` (`Sources/BrainKit/AgentSessionClient.swift`)
   and its entry to `BrainCatalog`.

A runtime that ships apart from BrainKit is a plugin instead (next section).

The state file keeps the active runtime's state at top level, named by `runtime`
(a file without `runtime` belongs to Codex), and other runtimes' conversations
under `conversations`, so switching back resumes them.

## Runtime plugins

A runtime plugin adds a runtime without changing BrainKit. It is a folder whose name is the
runtime's id, normally `~/Library/Application Support/BrainKit/Runtimes/<id>/`; the
environment variable `BRAINKIT_RUNTIMES_DIR` names another parent folder (tests and isolated
runs). `BrainService` finds the plugins there, reports them in its detections beside the
built-in runtimes, and passes each available one (trusted, with its executable and every tool
it requires found) to the companion with
`--runtime-plugin <id>=<folder>` and `--runtime-executable <id>=<path>`. Once given, the id
works everywhere a built-in's does: `--runtime`, `POST /v1/runtime`, the snapshot's `runtime`
and the state file.

The folder holds `runtime.json`:

```json
{
  "schema": 1,
  "id": "example-agent",
  "title": "Example Agent",
  "version": "1.2.0",
  "adapter": "adapter.mjs",
  "executable": "example-agent",
  "searchPaths": ["~/.example-agent/bin"],
  "installCommand": "brew install example-agent",
  "loginCommand": "example-agent login",
  "loginTitle": "Log In",
  "note": "One line a host may show beside the runtime.",
  "summary": "A sentence describing the runtime.",
  "docsURL": "https://example.com/example-agent"
}
```

| Field | |
|---|---|
| `schema` | `1` |
| `id` | `^[a-z][a-z0-9-]{0,31}$`, the folder's name, and not a built-in id (`codex`, `hermes`, `claude`) |
| `title` | the name a host shows |
| `version` | the plugin's version (semver) |
| `adapter` | the adapter module, relative to the folder |
| `executable` | the tool to find: a name looked up like the built-ins' tools (PATH, the common install folders, then `searchPaths`), or an absolute or `~/` path |
| `searchPaths` | optional extra folders to look in (`~/` allowed) |
| `installCommand`, `loginCommand`, `loginTitle` | optional shell commands (and the login button's title) a host may offer |
| `requires` | optional other tools the runtime needs, looked up like the built-ins' tools; the plugin is unavailable while one is missing, and the reason names it |
| `note` | optional one line a host may show |
| `summary`, `docsURL` | optional sentence describing the runtime, and an http(s) link to its documentation |

Unknown keys are ignored.

**Trust.** A plugin is refused unless its folder, its `runtime.json` and its adapter file are
each, checked without following links, not a symbolic link, owned by the current (effective)
user and writable by no one else (no group or world write bit), and the adapter's path stays
inside the folder, also with links in between resolved. BrainKit checks this when it detects
plugins; a refused plugin still appears in the detections, unavailable, with the reason. The
companion checks again immediately before importing the adapter; a plugin refused then (or
whose adapter fails to load) is still selectable, and starting it fails with the reason, like
any runtime that cannot start.

**Adapter.** The adapter default-exports a factory:

```js
export default function create(kit, { executable, toolServers, options }) {
  class ExampleRuntime extends kit.Runtime {
    static id = 'example-agent';          // must equal runtime.json's id
    static displayName = 'Example Agent';
    // start, submit, approve, cancel, reset, … as in Runtime interface above
  }
  return new ExampleRuntime();
}
```

- `kit` (exported as `kit` from `runtimes/plugins.mjs`) is a frozen object: `{ apiVersion: 1, Runtime, bounded, claude: { describe },
  toolServers: { allowedToolPatterns, claudeMcpServers } }` — the runtime base class and
  `bounded` from `runtimes/Runtime.mjs`, Claude Code's tool-call description from
  `runtimes/claude.mjs`, and the Claude Code tool-server helpers from `tool-servers.mjs`.
  An adapter imports nothing else from the companion.
- `executable` is the resolved absolute path from `--runtime-executable` (the host's override
  when the user set one); `toolServers` the host's validated tool servers, as built-in runtimes
  receive them; `options` is reserved and `{}`.
- The factory returns an instance of a `kit.Runtime` subclass whose `id` is the plugin's id;
  the session keys the saved conversation and the snapshot by that id. The factory may be
  async. The companion imports the adapter when the runtime is chosen, and again
  after the file changes.

`test/fixtures/echo-agent/` is a complete minimal plugin, exercised by `test/plugins.test.mjs`.

## HTTP contract

Every route requires `Authorization: Bearer <token>`. Host must be exactly
`127.0.0.1:<port>`; Origin and browser fetch-metadata headers are rejected. The
server binds IPv4 loopback only and does not send CORS headers. POST requires
`Content-Type: application/json`; request bodies are limited to 32 KiB. The Swift
client rejects redirects, accepts only IPv4 loopback HTTP, caps responses, and
polls complete snapshots so missed polls do not lose approvals.

- `GET /v1/session` — current snapshot.
- `POST /v1/turn` with `{ "text": "...", "requestId": "UUID" }` — submit once.
  Repeating one of the last 256 request IDs returns state without another turn.
  Active turns reject a different submission with 409. Text is at most 16,000 characters.
- `POST /v1/approval` with `{ "id": "opaque approval ID", "decision": "accept" }`
  or `"decline"` — answer the corresponding runtime request once.
  Session-wide approval decisions and permission-profile grants are never sent; only
  the specific action can be approved. A Codex file request may include a grantRoot
  hint, but accept approves only this patch and never caches folder access. Expired IDs return 409.
- `POST /v1/permissions` with `{ "mode": "approvedFolders", "approvedFolders": ["/absolute/workspace", "/absolute/other"] }`
  or mode `"fullAccess"` — save permissions while idle, returning the full snapshot.
  Both modes retain 1–32 existing absolute directories. Symlinks are canonicalized,
  duplicates removed, and the immutable companion workspace is always first.
  Removing the workspace returns 400; active/submitting turns return 409.
  Only this explicit authenticated endpoint can change permissions; turn input and
  approval responses cannot change the saved mode or folders.
- `POST /v1/cancel` with `{}` — request interruption; subsequent snapshots confirm it.
  Returns 409 if the runtime cannot interrupt.
- `POST /v1/session/reset` with `{}` — start a new conversation while idle.
- `POST /v1/runtime` with `{ "runtime": "codex" | "hermes" | "claude" | "<plugin id>" }` — switch
  runtime while idle (409 otherwise), or restart the current one after a failure.
  Only the name crosses HTTP; executables, URLs and tokens come from the command
  line. Permissions and recent request IDs carry over; each runtime's conversation
  is kept. The choice persists even if the runtime fails to start (503 with the
  reason; the snapshot shows `status: "failed"`).

Snapshots contain `threadId`, `turnId`, `status`, `output`, `progress`, `approvals`,
`error`, increasing `revision`, a process-specific `instanceId`, optional
`requestId`, `route`, `timing`, `permissions` (mode and approved folders),
`routing`, then `runtime` (the runtime ID), `capabilities`
(`approvals`, `folderScope`, `modelRouting`, `cancel`) and `sessionKey` (the external
session the runtime drives, in the runtime's own form, or null), and `toolServers`
(`names`, `active`, `note`; see Tool servers and host context). The fields before `runtime`
keep a fixed order and encoding, and new fields are only appended after them
(`test/snapshot-compat.test.mjs`).
Status is `idle`, `running`, `approval`, `interrupted`, or `failed`. `idle` with a
non-null turn ID means completion. `threadId` is the runtime's conversation ID and
`turnId` its turn ID (a Hermes run ID; a companion-generated UUID for Claude).
Output is bounded to 65,536 characters and resets at turn start. An approval has
`id`, `kind` (`command`, `fileChange`, or `tool`), `reason`, optional `command`, and
optional `cwd`. The revision resets when the companion restarts; `instanceId` allows
clients to detect even a restart between successful polls. `requestId` identifies
the submitted request only once an accepted turn is known. The receipt is persisted
before submission with the previous turn ID, then updated with the accepted turn ID.
After restart, the old completed turn is never labeled as a pending new request.
Clients with an uncertain POST response should reconcile against this ID, not cached
completion state; a missing matching receipt is not permission to replay the
operation. Clients must not speak a historical completion just because they reconnected.

## Verification

```sh
npm test
BRAINKIT_CODEX=/opt/homebrew/bin/codex npm run smoke
```

Tests use fakes and temporary files: the Codex adapter against an in-memory and a
spawned stdio JSON-RPC app-server (routing, streaming, approvals, interrupt, restart
receipts, permission policy), the Hermes adapter against a fake gateway speaking the
Runs API and SSE (deltas, progress, approval round trip, stop, degraded
capabilities, dropped stream, restart), the Claude adapter against a fake `claude`
that launches the real MCP permission bridge (streaming, resume, approvals, SIGINT
cancel, crash, permission modes, socket authentication), tool servers and host context
(validation, the exact Codex `-c` and Claude `--mcp-config`/`--allowedTools` arguments, Codex
MCP tool-call approvals, private host files, the Hermes note), runtime switching, runtime plugins (`runtime.json`, the trust refusals,
the kit, and the fixture plugin through a session and a spawned companion), HTTP
auth/Host/Origin checks, body limits, file permissions, and snapshot byte
compatibility. The smoke test initializes the installed Codex protocol and reads
signed-in status; it does not start a model turn.

The Swift side (client, transcript, supervisor, launcher, and a smoke test that runs
this companion with `test/fixtures/fake-codex.mjs` through one turn) runs from the
BrainKit package (`Kits/BrainKit` in the HUDKit repository):

```sh
swift test --filter BrainKitTests
```

`npm run acceptance` explicitly sends two real model turns using the signed-in
Codex account (normal usage applies). It creates its own temporary workspace,
asks the agent to create a test note and then revise the same note, and verifies
both contents and conversation continuity. It never auto-approves permission
requests. The temporary workspace path is printed so the result can be inspected.
This test passed against local Codex 0.153.2 on September 7, 2026.

Protocol reference: [official Codex App Server documentation](https://developers.openai.com/codex/app-server).
Implementation was checked against schemas generated locally with
`codex app-server generate-ts --out /tmp/codex-schema` from Codex 0.153.2, and its tool-server
configuration (`config/read`, `mcpServerStatus/list`) against Codex 0.155.1.

`npm run acceptance:permissions` runs five real model turns in fresh temporary
workspace/state folders, without modifying the user's companion settings. It
verifies full-access and approved-folder writes, denial outside approved folders,
one exact outside write approved once, and a subsequent outside write asking again.
The harness refuses all unexpected requests and approves only the exact literal toy
command (or its known Codex shell wrapper). Normal model usage applies. This passed
against installed Codex 0.153.2 on September 7, 2026.

One-action patch decisions were checked against the version-matched primary source:
[app-server decision mapping](https://github.com/openai/codex/blob/rust-v0.153.2/codex-rs/app-server/src/bespoke_event_handling.rs#L2001)
and [approval caching](https://github.com/openai/codex/blob/rust-v0.153.2/codex-rs/core/src/tools/sandboxing.rs#L70).
Only `acceptForSession` enters the approval cache; this companion never sends it.

The Hermes adapter was checked on September 26, 2026 against a real `hermes gateway`
(Hermes Agent 0.21.3, isolated `HERMES_HOME`, no model provider configured):
capabilities, run creation with `session_id`, Idempotency-Key replay of the same
run, SSE framing, and `run.failed` mapping. Model output, approvals and stop against a
provider-backed gateway are covered only by the fake gateway so far. The Claude
adapter was checked against Claude Code 2.1.283: streamed output, an approval
allowed and one denied through the MCP bridge, `--resume` continuity, and SIGINT
cancellation followed by a resumed turn.

### Voice model routing (Codex)

At startup the Codex runtime discovers the account's available models. A local rule
routes straightforward short questions and actions to GPT-5.6 Luna at low
reasoning effort; complex, destructive, or open-ended work goes to GPT-6 Astra
at medium effort. A short continuation of complex work keeps the stronger route.
The router chooses only models and effort values advertised by the runtime, with
available-model fallbacks; if discovery is unsupported, the runtime keeps its
configured model. Model selection does not change the folder or approval policy.
Hermes and Claude use their own configured model (`routing.available` is false).

There is no extra model call to classify a request, no background escalation, and
no automatic retry of a failed action on another model. Both routes use the same
conversation. Say “think carefully” when a request needs the stronger route.
Snapshots expose `routing` (available choices), `route` (choice and reason), and
`timing` (submission timestamp, first response, and completion milliseconds).
Completion includes tool and human approval waits; speech generation is separate.
The app shows these timings alongside local transcription and reply voice
preparation (synthesis start to playback). The warm polling connection is reused
between requests. Speech still starts after a completed agent turn and synthesis;
these measurements do not include the microphone's trailing-silence detector.

`voice-instructions.mjs` contains versioned voice guidance and short task playbooks
shared by every runtime (Codex developer instructions, Hermes run instructions,
Claude appended system prompt). It asks for brief answers, narrow approval requests,
verified actions, and loading only relevant installed skills. Permission speech
derives file operations and paths from the actual patch metadata, without reading
the diff or repeating the agent's rationale. Short commands retain their exact text
and working directory. Actions that cannot be disclosed briefly and completely
require Settings review.

`npm run acceptance:routing` sends two non-action questions in an isolated real
Codex conversation and reports route/timing while checking continuity. It uses
your signed-in account's model allowance. A September 8, 2026 run completed the
simple Luna request in 3.4 seconds and the Astra follow-up in 4.8 seconds; these
are individual measurements, not a general speed guarantee or a matched benchmark.
