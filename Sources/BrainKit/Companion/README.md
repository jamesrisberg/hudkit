# Brain companion

This Node process connects a macOS host app to a tool-capable agent runtime (the
"brain"). It ships inside BrainKit as a resource (`Companion/` in the
`HUDKit_BrainKit.bundle`), and a host app runs it through BrainKit's `BrainService`:
`node server.mjs --cwd <workspace> --runtime <choice> --state-dir <private state> --port <port>`,
restarting it with backoff and reading the token file directly (see
[docs/BRAINKIT.md](../../../docs/BRAINKIT.md)). Running it by hand, as below, is the
manual mode. Audio stays in the host app's local speech pipeline; this service
accepts only text. The runtime sends that text and relevant tool context to its
configured model provider and keeps its own conversation history on disk.

Three runtimes are built in:

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
- `--runtime codex|hermes|claude` — without it, the runtime last chosen (by flag or
  by the app) is read from the state directory; the first default is `codex`.
- `--state-dir /absolute/path` — private state (default `~/.brainkit-companion`).
- `--port 8789` — HTTP port on 127.0.0.1 (default 8788).
- `--codex /path/to/codex`, `--claude /path/to/claude` — executables if not on PATH
  (Homebrew Codex: `--codex /opt/homebrew/bin/codex`).
- `--runtime-url http://127.0.0.1:8642` — Hermes API server. Plain HTTP only on
  loopback; https elsewhere. Persisted in the state directory.
- `--runtime-token-file /path` (mode 0600) or `--runtime-token TOKEN` — Hermes
  `API_SERVER_KEY`. Prefer the file: arguments are visible in `ps`. The token is also
  read from `BRAINKIT_RUNTIME_TOKEN`, and otherwise from `API_SERVER_KEY` in
  `$HERMES_HOME/.env` (default `~/.hermes/.env`); the token is never persisted.
- `--assistant-name NAME` — the name the voice instructions give the assistant (one
  line, at most 64 characters). Without it the instructions name none.

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
       --mcp-config <bridge> --permission-prompt-tool mcp__brainkit_permissions__approve
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
| `snapshot()` → `{ routing }` | runtime-specific snapshot fields |
| `persistentState()` | extra JSON saved in the state directory, returned as `saved` |
| `capabilities` | `{ approvals, folderScope, modelRouting, cancel }` |
| `close()` | release processes and connections |

Events: `started {turnId}`, `output {turnId, text}` (the full visible text so far),
`progress {turnId, text}`, `approval {id, turnId, kind, reason, command, cwd}`,
`completed|failed|cancelled {turnId, output, error}`, `notice {error}`, and
`disconnected Error`. A runtime refuses requests it cannot represent (fail closed)
and declines its own pending approvals when a turn ends.

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

The state file keeps the active runtime's state at top level (the pre-runtime
format, which belongs to Codex) and other runtimes' conversations under
`conversations`, so switching back resumes them.

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
- `POST /v1/runtime` with `{ "runtime": "codex" | "hermes" | "claude" }` — switch
  runtime while idle (409 otherwise), or restart the current one after a failure.
  Only the name crosses HTTP; executables, URLs and tokens come from the command
  line. Permissions and recent request IDs carry over; each runtime's conversation
  is kept. The choice persists even if the runtime fails to start (503 with the
  reason; the snapshot shows `status: "failed"`).

Snapshots contain `threadId`, `turnId`, `status`, `output`, `progress`, `approvals`,
`error`, increasing `revision`, a process-specific `instanceId`, optional
`requestId`, `route`, `timing`, `permissions` (mode and approved folders),
`routing`, then `runtime` (the runtime ID) and `capabilities`
(`approvals`, `folderScope`, `modelRouting`, `cancel`). The fields before `runtime`
are byte-compatible with the pre-runtime companion (`test/snapshot-compat.test.mjs`).
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
cancel, crash, permission modes, socket authentication), runtime switching, HTTP
auth/Host/Origin checks, body limits, file permissions, and snapshot byte
compatibility. The smoke test initializes the installed Codex protocol and reads
signed-in status; it does not start a model turn.

The Swift side (client, transcript, supervisor, launcher, and a smoke test that runs
this companion with `test/fixtures/fake-codex.mjs` through one turn) runs from the
HUDKit repository root:

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
`codex app-server generate-ts --out /tmp/codex-schema` from Codex 0.153.2.
No MechaClaude source is embedded or patched into a third-party executable.

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
