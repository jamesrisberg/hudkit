import { EventEmitter } from 'node:events';

/**
 * The contract every agent runtime ("brain") implements for the companion.
 *
 * The companion's Session owns everything that must behave identically no matter
 * which brain is plugged in: request-ID deduplication and receipts, permission
 * validation and persistence, opaque approval IDs, timing, and the HTTP snapshot.
 * A runtime adapter owns only the protocol to one agent: how to start or resume a
 * conversation, send a turn, answer an approval, interrupt, and report progress.
 *
 * Lifecycle (all methods are called by Session, never concurrently for one turn):
 *
 *   start(cwd, { saved, permissions, instructions })
 *     -> Promise<{ threadId, lastTurn }>
 *     Connect to the agent, then create or resume a conversation. `saved` is the
 *     runtime's own persisted state (whatever persistentState() returned last
 *     time, plus `threadId`). `lastTurn` is the most recent turn of a resumed
 *     conversation, or null: { turnId, status, output, error } where status is
 *     'idle' | 'running' | 'interrupted' | 'failed'. It is displayed after a
 *     restart and is never resubmitted.
 *
 *   submit(text, { requestId, permissions }) -> Promise<{ turnId }>
 *     Start exactly one turn. Never retry it internally: a lost response may hide
 *     an accepted turn. Events for the turn may be emitted before this resolves,
 *     including its completion.
 *
 *   approve(id, decision)
 *     Answer an approval this runtime emitted. decision is 'accept' (this one
 *     action only, never session-wide) or 'decline'. Synchronous; delivery errors
 *     surface as a 'notice' or 'disconnected' event.
 *
 *   setPermissions(permissions) -> Promise<void>
 *     { mode: 'approvedFolders' | 'fullAccess', approvedFolders: [absolute dirs] },
 *     already validated. Applies from the next turn at the latest.
 *
 *   cancel(turnId) -> Promise<void>
 *     Request interruption. Completion is reported later with a 'cancelled' (or
 *     'completed'/'failed' if the turn finished first) event.
 *
 *   reset({ permissions }) -> Promise<{ threadId }>
 *     Start a new conversation. Only called while idle.
 *
 *   snapshot() -> { routing, route }
 *     Runtime-specific snapshot fields (see Session.snapshot()).
 *
 *   persistentState() -> object
 *     Extra JSON persisted in the state directory and passed back as `saved`.
 *
 *   close()
 *     Release processes, sockets and connections. Must not throw.
 *
 * Events (emit with exactly these names; 'error' is reserved by EventEmitter):
 *
 *   'started'      { turnId }                   the runtime assigned/confirmed a turn ID
 *   'output'       { turnId, text }             the full visible answer text so far
 *   'progress'     { turnId, text }             short human-readable activity line
 *   'approval'     { id, turnId, kind, reason, command, cwd }
 *                  kind is 'command' | 'fileChange' | 'tool'. The runtime must have
 *                  already refused requests it cannot represent (fail closed).
 *   'completed'    { turnId, output }           turn finished normally
 *   'failed'       { turnId, output, error }    turn ended with an error
 *   'cancelled'    { turnId, output }           turn was interrupted
 *   'notice'       { error }                    non-fatal runtime error to display
 *   'disconnected' Error                        the runtime is gone; Session fails closed
 *
 * When a turn ends, the runtime itself declines any approvals still pending for
 * it; Session drops its opaque IDs for them.
 */
export class Runtime extends EventEmitter {
  /** Stable identifier used by --runtime and the snapshot's `runtime` field. */
  static id = 'abstract';
  /** Human-readable name for status text. */
  static displayName = 'Agent';

  get id() { return this.constructor.id; }
  get displayName() { return this.constructor.displayName; }

  /**
   * What this runtime can honour. Session and the app use it to stay truthful:
   * approvals   - the runtime can pause for a per-action human decision
   * folderScope - approved folders are enforced by the runtime's sandbox
   * modelRouting- the companion chooses a model per request
   * cancel      - turns can be interrupted
   */
  get capabilities() { return { approvals: false, folderScope: false, modelRouting: false, cancel: false }; }

  async start(_cwd, _options) { throw new Error(`${this.displayName} runtime does not implement start`); }
  async submit(_text, _options) { throw new Error(`${this.displayName} runtime does not implement submit`); }
  approve(_id, _decision) { throw new Error(`${this.displayName} runtime does not implement approvals`); }
  async setPermissions(_permissions) {}
  async cancel(_turnId) { throw Object.assign(new Error(`${this.displayName} runtime cannot interrupt a turn`), { status: 409 }); }
  async reset(_options) { throw new Error(`${this.displayName} runtime does not implement reset`); }
  snapshot() { return { routing: { mode: 'automatic', available: false, fastModel: null, deepModel: null }, route: null }; }
  persistentState() { return {}; }
  close() {}
}

export const bounded = (value, limit = 16384) => String(value ?? '').slice(0, limit);
