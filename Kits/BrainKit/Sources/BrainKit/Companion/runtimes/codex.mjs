import { Runtime, bounded } from './Runtime.mjs';
import { CodexRpc } from './codex-rpc.mjs';
import { discoverModels, routeInput } from './codex-routing.mjs';

const APPROVAL_METHODS = ['item/commandExecution/requestApproval', 'item/fileChange/requestApproval'];

/**
 * Codex CLI through `codex app-server` (stdio JSON-RPC). Codex enforces the folder
 * scope with its own sandbox; approvals are real JSON-RPC requests answered once.
 * Protocol reference: https://developers.openai.com/codex/app-server
 */
export class CodexRuntime extends Runtime {
  static id = 'codex';
  static displayName = 'Codex';

  /** `transport` replaces the spawned app-server (tests); it must look like CodexRpc. */
  constructor({ executable = 'codex', transport = null } = {}) {
    super();
    this.executable = executable; this.rpc = transport;
    this.threadId = null; this.turnId = null; this.active = false;
    this.pending = new Map(); // JSON-RPC request ID -> turn ID
    this.items = new Map(); this.finalItems = new Map(); this.fileChanges = new Map();
    this.models = {}; this.lastRouteTier = null; this.permissions = null;
  }
  get capabilities() { return { approvals: true, folderScope: true, modelRouting: true, cancel: true }; }
  get dead() { return Boolean(this.rpc?.dead); }

  async start(cwd, { saved = {}, permissions, instructions }) {
    this.cwd = cwd; this.permissions = permissions; this.instructions = instructions;
    // Advisory affinity survives restart without inventing a historical model or timing.
    this.lastRouteTier = ['fast', 'deep'].includes(saved.lastRouteTier) ? saved.lastRouteTier : null;
    this.rpc ??= new CodexRpc({ executable: this.executable, cwd });
    this.rpc.on('message', message => this.onMessage(message));
    this.rpc.on('disconnect', error => { this.pending.clear(); this.active = false; this.emit('disconnected', error); });
    await this.rpc.request('initialize', { clientInfo: { name: 'brainkit', title: 'BrainKit', version: '0.1.0' }, capabilities: { experimentalApi: false } });
    this.rpc.send({ method: 'initialized', params: {} });
    const policy = this.threadPolicy();
    const result = saved.threadId ? await this.resumeOrStart(saved.threadId, policy) : await this.rpc.request('thread/start', policy);
    this.threadId = result.thread.id;
    const last = result.thread.turns?.at(-1);
    let lastTurn = null;
    if (last) {
      this.turnId = last.id; this.active = last.status === 'inProgress';
      lastTurn = this.turnResult(last);
    }
    // Older runtimes may not support discovery. A failed catalog lookup must not
    // trigger a model turn or replay a prior request. Runtime disconnect stays fatal.
    try { this.models = await discoverModels(this.rpc); }
    catch (error) { if (this.rpc.dead) throw error; this.models = {}; }
    return { threadId: this.threadId, lastTurn };
  }
  // Codex writes a thread to disk only once it has a turn, so a thread started but never used
  // cannot be resumed after a restart ("no rollout found"); start a new one in its place.
  // Every other resume failure stays fatal.
  async resumeOrStart(threadId, policy) {
    try { return await this.rpc.request('thread/resume', { ...policy, threadId }); }
    catch (error) {
      if (this.rpc.dead || !/no rollout found/i.test(String(error?.message ?? error))) throw error;
      return this.rpc.request('thread/start', policy);
    }
  }
  async submit(text, { permissions, beforeSend = async () => {} }) {
    this.permissions = permissions;
    const route = routeInput(text, this.models, { tier: this.lastRouteTier });
    if (['fast', 'deep'].includes(route.tier)) this.lastRouteTier = route.tier;
    await beforeSend({ route });
    this.items.clear(); this.finalItems.clear(); this.fileChanges.clear();
    this.turnId = null; this.active = true;
    try {
      const result = await this.rpc.request('turn/start', { threadId: this.threadId, input: [{ type: 'text', text, text_elements: [] }], ...this.turnPolicy(), ...(route.model ? { model: route.model } : {}), ...(route.effort ? { effort: route.effort } : {}) });
      this.turnId ??= result.turn.id;
      return { turnId: result.turn.id };
    } catch (error) {
      if (!this.turnId) this.active = false;
      throw error;
    }
  }
  onMessage(message) {
    const { method, params: p = {} } = message;
    if (message.id !== undefined) {
      if (!this.active || typeof p.turnId !== 'string' || p.threadId !== this.threadId || (this.turnId && p.turnId !== this.turnId) || this.pending.size >= 8 || (p.grantRoot != null && method !== 'item/fileChange/requestApproval') || !APPROVAL_METHODS.includes(method)) {
        this.rpc.reject(message.id);
        this.emit('progress', { turnId: this.turnId, text: `Unsupported request was denied: ${bounded(method, 128)}` });
        return;
      }
      this.pending.set(message.id, p.turnId);
      this.emit('approval', { id: message.id, turnId: p.turnId, kind: method.includes('commandExecution') ? 'command' : 'fileChange', reason: p.reason || 'Permission requested by Codex', command: p.command ? bounded(p.command) : this.fileChanges.get(p.itemId) ?? null, cwd: p.cwd ?? null });
      return;
    }
    if (p.threadId !== this.threadId) return;
    if (method === 'turn/started') { this.turnId = p.turn.id; this.emit('started', { turnId: p.turn.id }); }
    if (method === 'item/started') {
      const item = p.item;
      if (item.type === 'fileChange') {
        this.fileChanges.set(item.id, bounded(JSON.stringify(item.changes, null, 2)));
        if (this.fileChanges.size > 8) this.fileChanges.delete(this.fileChanges.keys().next().value);
      }
      if (item.type === 'agentMessage') {
        if (this.items.size >= 64) this.items.delete(this.items.keys().next().value);
        this.items.set(item.id, '');
      }
      else this.emit('progress', { turnId: this.turnId, text: bounded(item.command || item.tool || (item.type === 'fileChange' ? 'Editing files' : 'Working'), 1024) });
    }
    if (method === 'item/agentMessage/delta') {
      if (!this.items.has(p.itemId) && this.items.size >= 64) this.items.delete(this.items.keys().next().value);
      this.items.set(p.itemId, bounded((this.items.get(p.itemId) || '') + p.delta, 65536));
      this.emit('output', { turnId: this.turnId, text: [...this.items.values()].join('\n\n') });
    }
    if (method === 'item/completed' && p.item.type === 'agentMessage') {
      if (!this.items.has(p.item.id) && this.items.size >= 64) this.items.delete(this.items.keys().next().value);
      this.items.set(p.item.id, bounded(p.item.text, 65536));
      if (p.item.phase === 'final_answer') {
        if (this.finalItems.size >= 8) this.finalItems.delete(this.finalItems.keys().next().value);
        this.finalItems.set(p.item.id, bounded(p.item.text, 65536));
      }
      this.emit('output', { turnId: this.turnId, text: [...this.items.values()].join('\n\n') });
    }
    if (method === 'turn/completed' && (!this.turnId || p.turn.id === this.turnId)) {
      // Anything still awaiting a decision is refused when its turn ends.
      for (const id of this.pending.keys()) this.rpc.reply(id, { decision: 'decline' });
      this.pending.clear(); this.active = false; this.turnId = p.turn.id;
      const result = this.turnResult(p.turn);
      this.emit(result.status === 'idle' ? 'completed' : result.status === 'interrupted' ? 'cancelled' : 'failed', result);
    }
    if (method === 'error' && !p.willRetry) this.emit('notice', { error: p.error?.message || 'Agent error' });
  }
  /** A Codex turn as the runtime contract's { turnId, status, output, error }. */
  turnResult(turn) {
    const messages = (turn.items ?? []).filter(item => item.type === 'agentMessage');
    const finalMessages = messages.filter(item => item.phase === 'final_answer');
    const text = (finalMessages.length ? finalMessages : messages).map(item => item.text).join('\n\n');
    const status = turn.status === 'completed' ? 'idle' : turn.status === 'interrupted' ? 'interrupted' : turn.status === 'inProgress' ? 'running' : 'failed';
    return { turnId: turn.id, status, output: text || [...this.finalItems.values()].join('\n\n'), error: turn.error?.message ?? null };
  }
  approve(id, decision) {
    if (!this.pending.has(id)) throw Object.assign(new Error('Approval is no longer pending'), { status: 409 });
    // Even when file approval includes a grantRoot hint, accept maps to Approved;
    // only acceptForSession maps to the cached ApprovedForSession (Codex 0.153.2).
    this.rpc.reply(id, { decision: decision === 'accept' ? 'accept' : 'decline' });
    this.pending.delete(id);
  }
  async setPermissions(permissions) { this.permissions = permissions; }
  async cancel(turnId) {
    await this.rpc.request('turn/interrupt', { threadId: this.threadId, turnId });
  }
  async reset({ permissions }) {
    this.permissions = permissions;
    const result = await this.rpc.request('thread/start', this.threadPolicy());
    this.items.clear(); this.finalItems.clear(); this.fileChanges.clear(); this.lastRouteTier = null;
    this.threadId = result.thread.id; this.turnId = null; this.active = false;
    return { threadId: this.threadId };
  }
  snapshot() { return { routing: { mode: 'automatic', available: Boolean(this.models.fast && this.models.deep), fastModel: this.models.fast?.model ?? null, deepModel: this.models.deep?.model ?? null } }; }
  persistentState() { return { lastRouteTier: this.lastRouteTier }; }
  close() { this.rpc?.close(); }

  threadPolicy() {
    const full = this.permissions.mode === 'fullAccess';
    return { cwd: this.cwd, sandbox: full ? 'danger-full-access' : 'workspace-write',
      approvalPolicy: full ? 'never' : 'on-request', approvalsReviewer: 'user',
      config: { 'sandbox_workspace_write.network_access': false,
        'sandbox_workspace_write.writable_roots': this.permissions.approvedFolders,
        'sandbox_workspace_write.exclude_tmpdir_env_var': true,
        'sandbox_workspace_write.exclude_slash_tmp': true },
      developerInstructions: this.instructions };
  }
  turnPolicy() {
    const full = this.permissions.mode === 'fullAccess';
    return { cwd: this.cwd, approvalPolicy: full ? 'never' : 'on-request', approvalsReviewer: 'user',
      sandboxPolicy: full ? { type: 'dangerFullAccess' } : { type: 'workspaceWrite',
        writableRoots: this.permissions.approvedFolders, networkAccess: false,
        excludeTmpdirEnvVar: true, excludeSlashTmp: true } };
  }
}
