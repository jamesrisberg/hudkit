import { randomUUID } from 'node:crypto';
import { realpath, stat } from 'node:fs/promises';
import path from 'node:path';
import { bounded } from './runtimes/Runtime.mjs';
import { voiceInstructions } from './voice-instructions.mjs';

const ACTIVE = ['running', 'approval'];
const RUNTIME_EVENTS = ['started', 'output', 'progress', 'approval', 'approvalResolved', 'completed', 'failed', 'cancelled', 'notice', 'disconnected', 'persist'];

/**
 * Runtime-agnostic conversation state behind the HTTP API. Everything the app relies
 * on (deduplication, receipts, permission scope, opaque approval IDs, snapshots) lives
 * here so every runtime adapter (runtimes/*.mjs) behaves the same to the app.
 */
export class Session {
  constructor({ runtime, cwd, saved = {}, save = async () => {}, createRuntime = null, instructions = voiceInstructions(), toolServers = [] }) {
    this.runtime = runtime; this.cwd = cwd; this.save = save; this.createRuntime = createRuntime; this.instructions = instructions;
    this.toolServerNames = toolServers.map(server => server.name);
    this.hasSavedPermissions = saved.permissions !== undefined;
    this.permissions = saved.permissions ?? { mode: 'approvedFolders', approvedFolders: [cwd] };
    // State of runtimes that are not active, so switching back resumes their conversation.
    // A state file without `runtime` belongs to Codex.
    this.conversations = saved.conversations && typeof saved.conversations === 'object' ? { ...saved.conversations } : {};
    const savedRuntime = typeof saved.runtime === 'string' ? saved.runtime : 'codex';
    const { permissions: _p, requestIds: _r, receipt: _c, runtime: _n, conversations: _s, cwd: _w, ...runtimeState } = saved;
    let receipt = saved.receipt ?? null;
    if (savedRuntime === runtime.id) this.runtimeSaved = runtimeState;
    else {
      if (runtimeState.threadId) this.conversations[savedRuntime] = runtimeState;
      this.runtimeSaved = this.conversations[runtime.id] ?? {};
      // A receipt refers to the other runtime's turns and can never label this one's.
      receipt = null;
    }
    delete this.conversations[runtime.id];
    this.state = { threadId: this.runtimeSaved.threadId ?? null, turnId: null, status: 'idle', output: '', progress: 'Ready', approvals: [], error: null, revision: 0, instanceId: randomUUID(), requestId: null };
    this.approvals = new Map(); this.seenRequests = new Set(saved.requestIds ?? []);
    this.receipt = receipt;
    this.busy = false; this.ready = false;
    this.state.route = null; this.state.timing = null;
    this.listeners = null; this.started = false;
  }
  update(fields) { Object.assign(this.state, fields); this.state.revision++; }
  snapshot() {
    const runtime = this.runtime.snapshot();
    return structuredClone({ ...this.state, permissions: this.permissions, routing: runtime.routing,
      runtime: this.runtime.id, capabilities: this.runtime.capabilities, sessionKey: runtime.sessionKey ?? null,
      toolServers: this.toolServerStatus() });
  }
  /** The host's tool servers and whether the running runtime gives them to the agent. */
  toolServerStatus() {
    const names = this.toolServerNames;
    const active = names.length > 0 && this.runtime.supportsToolServers;
    const note = names.length && !active
      ? `${this.runtime.displayName} cannot use this app's tools (${names.join(', ')}); it only has the tools configured in ${this.runtime.displayName} itself. Choose Codex, Claude or mclaude to use them.`
      : null;
    return { names: [...names], active, note };
  }
  bind(runtime) {
    const handlers = {
      started: ({ turnId }) => {
        // A turn nobody submitted here was started in another client of the same session
        // (mclaude in MechaHUD): it belongs to no request and replaces the last answer.
        if (!this.busy && !ACTIVE.includes(this.state.status)) {
          this.approvals.clear();
          return this.update({ turnId, status: 'running', requestId: null, route: null, timing: null, output: '', error: null, approvals: [], progress: 'Working' });
        }
        this.correlate(turnId); this.update({ turnId, status: 'running' });
      },
      output: ({ text }) => { this.markFirstResponse(); this.update({ output: bounded(text, 65536) }); },
      progress: ({ text }) => this.update({ progress: bounded(text, 1024) }),
      approval: request => this.onApproval(request),
      approvalResolved: ({ id }) => this.onApprovalResolved(id),
      completed: event => this.onTurnEnd(event, 'idle'),
      cancelled: event => this.onTurnEnd(event, 'interrupted'),
      failed: event => this.onTurnEnd(event, 'failed'),
      notice: ({ error }) => this.update({ error: bounded(error || 'Agent error') }),
      persist: () => {
        // Before start() returns, persist() writes what was saved for the runtime; keep that current.
        if (!this.started) this.runtimeSaved = { ...this.runtimeSaved, ...runtime.persistentState() };
        this.persist().catch(error => this.update({ error: bounded(`Unable to save session state: ${error.message}`) }));
      },
      disconnected: error => {
        this.ready = false; this.approvals.clear();
        this.update({ status: 'failed', error: bounded(error?.message ?? error), approvals: [], progress: 'Runtime disconnected' });
      },
    };
    for (const name of RUNTIME_EVENTS) runtime.on(name, handlers[name]);
    this.listeners = { runtime, handlers };
  }
  unbind() {
    if (!this.listeners) return;
    for (const name of RUNTIME_EVENTS) this.listeners.runtime.off(name, this.listeners.handlers[name]);
    this.listeners = null;
  }
  async initialize() {
    // Validate saved scope before contacting the runtime; corrupt state never broadens access.
    if (this.hasSavedPermissions) this.permissions = await this.validatePermissions(this.permissions, { savedScope: true });
    this.bind(this.runtime);
    this.applyStart(await this.runtime.start(this.cwd, { saved: this.runtimeSaved, permissions: this.permissions, instructions: this.instructions }));
    this.started = true;
    await this.persist(); this.ready = true;
  }
  applyStart({ threadId, lastTurn }) {
    this.update({ threadId });
    // After process restart show the last known turn. Never silently resubmit it.
    if (lastTurn) {
      const receipt = this.receipt;
      // A crash before the turn started must never label the previous answer as this request.
      if (receipt && (receipt.acceptedTurnId ? receipt.acceptedTurnId === lastTurn.turnId : lastTurn.turnId !== receipt.previousTurnId)) {
        receipt.acceptedTurnId = lastTurn.turnId;
        this.update({ requestId: receipt.requestId });
      }
      this.finishTurn(lastTurn);
    }
  }
  async persist(permissions = this.permissions) {
    // A runtime that never started knows nothing yet: keep what was saved for it.
    const runtimeState = this.started ? this.runtime.persistentState() : { ...this.runtimeSaved };
    delete runtimeState.threadId;
    await this.save({ permissions, ...runtimeState, threadId: this.state.threadId,
      requestIds: [...this.seenRequests].slice(-256), receipt: this.receipt ? { ...this.receipt } : null,
      runtime: this.runtime.id, conversations: this.conversations });
  }
  async submit(text, requestId) {
    if (!this.ready) throw Object.assign(new Error('Runtime is not ready'), { status: 503 });
    if (this.seenRequests.has(requestId)) return this.snapshot();
    if (this.busy || ACTIVE.includes(this.state.status)) throw Object.assign(new Error('A turn is already active'), { status: 409 });
    this.busy = true;
    try {
      this.receipt = { requestId, previousTurnId: this.state.turnId, acceptedTurnId: null };
      this.seenRequests.add(requestId);
      if (this.seenRequests.size > 256) this.seenRequests.delete(this.seenRequests.values().next().value);
      const result = await this.runtime.submit(text, { requestId, permissions: this.permissions,
        // The runtime calls this immediately before dispatching the turn, and must not
        // dispatch if it throws: an uncertain request must never replay.
        beforeSend: async ({ route = null } = {}) => {
          await this.persist();
          this.update({ route, timing: { startedAt: Date.now(), firstResponseMs: null, completedMs: null } });
          this.update({ status: 'running', turnId: null, requestId: null, output: '', error: null, progress: 'Thinking', approvals: [] });
        } });
      // Events may arrive before the response, including completion.
      if (!this.state.turnId) this.update({ turnId: result.turnId });
      this.correlate(result.turnId);
      await this.persist();
      return this.snapshot();
    } catch (error) {
      // A failed post-start disk write does not mean the already accepted action stopped.
      if (this.state.turnId && ACTIVE.includes(this.state.status)) this.update({ error: bounded(error.message), progress: 'Turn active; unable to save latest state' });
      else this.update({ status: 'failed', error: bounded(error.message), progress: 'Unable to start turn' });
      throw error;
    }
    finally { this.busy = false; }
  }
  onApproval(request) {
    if (!ACTIVE.includes(this.state.status) || this.approvals.size >= 8 || (this.state.turnId && request.turnId && request.turnId !== this.state.turnId)) {
      this.runtime.approve(request.id, 'decline');
      this.update({ progress: `Unexpected approval request was denied: ${bounded(request.kind, 128)}` });
      return;
    }
    const id = randomUUID(); this.approvals.set(id, { runtimeId: request.id, turnId: request.turnId ?? this.state.turnId });
    this.update({ status: 'approval', approvals: [...this.state.approvals, { id, kind: request.kind, reason: bounded(request.reason || 'Permission requested'), command: request.command ? bounded(request.command) : null, cwd: request.cwd ? bounded(request.cwd) : null }], progress: 'Waiting for your approval' });
  }
  /** The runtime withdrew an approval (answered in another client of the same session). */
  onApprovalResolved(runtimeId) {
    const entry = [...this.approvals].find(([, value]) => value.runtimeId === runtimeId);
    if (!entry) return;
    this.approvals.delete(entry[0]);
    const approvals = this.state.approvals.filter(item => item.id !== entry[0]);
    this.update({ approvals, status: approvals.length ? 'approval' : 'running', progress: approvals.length ? 'Waiting for your approval' : 'Answered elsewhere' });
  }
  onTurnEnd({ turnId, output = '', error = null }, status) {
    if (this.state.turnId && turnId !== this.state.turnId) return;
    this.finishTurn({ turnId, status, output, error });
    // Runtimes learn state during a turn (e.g. Claude's session now exists). Best effort:
    // the next mutation persists again, and a failure here changes nothing already done.
    this.persist().catch(error => this.update({ error: bounded(`Unable to save session state: ${error.message}`) }));
  }
  markFirstResponse() {
    const timing = this.state.timing;
    if (timing && timing.firstResponseMs === null) this.update({ timing: { ...timing, firstResponseMs: Math.max(0, Date.now() - timing.startedAt) } });
  }
  correlate(turnId) {
    if (!this.receipt || turnId === this.receipt.previousTurnId) return;
    if (this.receipt.acceptedTurnId && this.receipt.acceptedTurnId !== turnId) return;
    this.receipt.acceptedTurnId = turnId;
    this.update({ requestId: this.receipt.requestId });
  }
  finishTurn({ turnId, status, output, error }) {
    this.correlate(turnId);
    if (output) this.markFirstResponse();
    // The runtime declines its own pending approvals when a turn ends.
    this.approvals.clear();
    if (this.state.timing && status !== 'running') this.update({ timing: { ...this.state.timing, completedMs: Math.max(0, Date.now() - this.state.timing.startedAt) } });
    const progress = { idle: 'Done', interrupted: 'Interrupted', running: 'Working', failed: 'Turn failed' }[status] ?? 'Turn failed';
    this.update({ turnId, status: progress === 'Turn failed' ? 'failed' : status, output: bounded(output || this.state.output, 65536), error: error ? bounded(error) : null, approvals: [], progress });
  }
  approve(id, decision) {
    const approval = this.approvals.get(id);
    if (!['accept', 'decline'].includes(decision)) throw Object.assign(new Error('Only a one-action approval or denial is supported'), { status: 400 });
    if (!approval || !ACTIVE.includes(this.state.status) || (this.state.turnId && approval.turnId !== this.state.turnId)) throw Object.assign(new Error('Approval is no longer pending'), { status: 409 });
    // accept always means this one action; session-wide grants are never sent.
    this.runtime.approve(approval.runtimeId, decision);
    this.approvals.delete(id);
    const approvals = this.state.approvals.filter(item => item.id !== id);
    this.update({ approvals, status: approvals.length ? 'approval' : 'running', progress: decision === 'accept' ? 'Permission granted once' : 'Permission denied' });
    return this.snapshot();
  }
  async validatePermissions(value, { savedScope = false } = {}) {
    const invalid = message => Object.assign(new Error(message), { status: 400 });
    if (!value || !['approvedFolders', 'fullAccess'].includes(value.mode) || !Array.isArray(value.approvedFolders) || value.approvedFolders.length < 1 || value.approvedFolders.length > 32 || Object.keys(value).some(key => !['mode', 'approvedFolders'].includes(key))) throw invalid('Choose a permission mode and between 1 and 32 approved folders');
    const folders = [];
    for (const folder of value.approvedFolders) {
      if (typeof folder !== 'string' || folder.length > 4096 || !path.isAbsolute(folder) || folder.includes('\0')) throw invalid('Approved folders must be absolute directory paths');
      let canonical;
      try { canonical = await realpath(folder); if (!(await stat(canonical)).isDirectory()) throw new Error(); }
      catch { throw invalid(`Approved folder is not an accessible directory: ${bounded(folder, 256)}`); }
      if (savedScope && canonical !== folder) throw invalid(`Saved approved folder now points somewhere else: ${bounded(folder, 256)}. Restore the original folder before restarting; reselect changed folders explicitly in Settings.`);
      if (!folders.includes(canonical)) folders.push(canonical);
    }
    if (!folders.includes(this.cwd)) throw invalid('The companion workspace must remain in approved folders');
    return { mode: value.mode, approvedFolders: [this.cwd, ...folders.filter(folder => folder !== this.cwd)] };
  }
  async setPermissions(value) {
    if (!this.ready) throw Object.assign(new Error('Runtime is not ready'), { status: 503 });
    if (this.busy || ACTIVE.includes(this.state.status) || this.approvals.size) throw Object.assign(new Error('Finish or interrupt the active turn before changing permissions'), { status: 409 });
    this.busy = true;
    try {
      const permissions = await this.validatePermissions(value);
      // Commit to disk before publishing. Every next turn explicitly replaces the runtime policy.
      await this.persist(permissions);
      this.permissions = permissions;
      await this.runtime.setPermissions(permissions);
      this.update({ progress: 'Permissions saved' });
      return this.snapshot();
    } finally { this.busy = false; }
  }
  async reset() {
    if (!this.ready) throw Object.assign(new Error('Runtime is not ready'), { status: 503 });
    if (this.busy || ACTIVE.includes(this.state.status)) throw Object.assign(new Error('Interrupt the active turn before starting a new conversation'), { status: 409 });
    this.busy = true;
    try {
      const { threadId } = await this.runtime.reset({ permissions: this.permissions });
      this.seenRequests.clear(); this.receipt = null;
      this.update({ route: null, timing: null, threadId, turnId: null, requestId: null, status: 'idle', output: '', progress: 'Ready', approvals: [], error: null });
      await this.persist(); return this.snapshot();
    } finally { this.busy = false; }
  }
  async cancel() {
    if (!this.state.turnId || !ACTIVE.includes(this.state.status)) throw Object.assign(new Error('No interruptible turn is active'), { status: 409 });
    for (const [id] of this.approvals) this.approve(id, 'decline');
    this.update({ progress: 'Interrupt requested' });
    await this.runtime.cancel(this.state.turnId);
    // Remain running until the runtime confirms interruption.
    return this.snapshot();
  }
  /**
   * Replace the active runtime (or restart the same one after a failure). Only while
   * idle. The previous runtime's conversation is kept so switching back resumes it.
   */
  async switchRuntime(name) {
    if (!this.createRuntime) throw Object.assign(new Error('Runtime switching is not available'), { status: 400 });
    if (this.busy || ACTIVE.includes(this.state.status)) throw Object.assign(new Error('Finish or interrupt the active turn before switching runtime'), { status: 409 });
    if (name === this.runtime.id && this.ready) return this.snapshot();
    this.busy = true;
    try {
      const next = this.createRuntime(name);
      const previous = this.runtime; const restart = previous.id === next.id;
      if (this.state.threadId) this.conversations[previous.id] = { ...(this.started ? previous.persistentState() : this.runtimeSaved), threadId: this.state.threadId };
      this.unbind(); previous.close();
      // Restarting the same runtime keeps the receipt so an uncertain request can still
      // be reconciled against the resumed conversation; another runtime never can.
      this.runtime = next; this.ready = false; this.started = false; this.approvals.clear();
      if (!restart) this.receipt = null;
      this.runtimeSaved = this.conversations[next.id] ?? {};
      delete this.conversations[next.id];
      this.update({ threadId: null, turnId: null, requestId: null, status: 'idle', output: '', progress: `Starting ${next.displayName}`, approvals: [], error: null, route: null, timing: null });
      try {
        this.bind(next);
        this.applyStart(await next.start(this.cwd, { saved: this.runtimeSaved, permissions: this.permissions, instructions: this.instructions }));
        this.started = true;
        if (this.state.status === 'idle' && !this.state.turnId) this.update({ progress: 'Ready' });
        this.ready = true;
      } catch (error) {
        // Keep the saved conversation so a later retry resumes it.
        this.update({ status: 'failed', threadId: this.runtimeSaved.threadId ?? null, error: bounded(error.message), progress: `Unable to start ${next.displayName}` });
      }
      // The choice persists even when the runtime is not reachable yet.
      await this.persist();
      if (!this.ready) throw Object.assign(new Error(this.state.error), { status: 503 });
      return this.snapshot();
    } finally { this.busy = false; }
  }
}
