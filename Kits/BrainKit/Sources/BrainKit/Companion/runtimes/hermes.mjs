import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
import { Runtime, bounded } from './Runtime.mjs';

const TERMINAL = { 'run.completed': 'completed', 'run.failed': 'failed', 'run.cancelled': 'cancelled', 'run.interrupted': 'cancelled' };
const TERMINAL_STATUS = { completed: 'completed', failed: 'failed', cancelled: 'cancelled', interrupted: 'cancelled' };
const LOOPBACK = new Set(['127.0.0.1', 'localhost', '[::1]']);

/** Reads the API server settings `hermes gateway` itself uses from $HERMES_HOME/.env. */
export async function readHermesEnvironment(home = process.env.HERMES_HOME || path.join(homedir(), '.hermes')) {
  let text;
  try { text = await readFile(path.join(home, '.env'), 'utf8'); } catch { return {}; }
  const values = {};
  for (const line of text.split('\n')) {
    const match = /^\s*(?:export\s+)?(API_SERVER_KEY|API_SERVER_PORT|API_SERVER_HOST)\s*=\s*(.*?)\s*$/.exec(line);
    if (match) values[match[1]] = match[2].replace(/^(['"])(.*)\1$/, '$2');
  }
  return values;
}

/** Validates a Hermes base URL: plain HTTP only on loopback, never credentials or a query. */
export function hermesURL(value) {
  let url;
  try { url = new URL(value); } catch { throw Object.assign(new Error('The Hermes URL is invalid'), { status: 400 }); }
  if (!['http:', 'https:'].includes(url.protocol) || (url.protocol === 'http:' && !LOOPBACK.has(url.hostname)) || url.username || url.password || url.search || url.hash)
    throw Object.assign(new Error('The Hermes URL must be http://127.0.0.1:<port> (or https) without credentials or query'), { status: 400 });
  return url.href.replace(/\/+$/, '');
}

/** Parses a Server-Sent Events body into JSON `data:` payloads; comment lines are skipped. */
export async function readEvents(body, onEvent, limit = 1024 * 1024) {
  const decoder = new TextDecoder(); let buffer = '';
  for await (const chunk of body) {
    buffer += decoder.decode(chunk, { stream: true });
    if (buffer.length > limit) throw new Error('Hermes event exceeded size limit');
    let boundary;
    while ((boundary = buffer.search(/\r?\n\r?\n/)) >= 0) {
      const block = buffer.slice(0, boundary); buffer = buffer.slice(boundary).replace(/^\r?\n\r?\n/, '');
      const data = block.split(/\r?\n/).filter(line => line.startsWith('data:')).map(line => line.slice(5).replace(/^ /, '')).join('\n');
      if (!data) continue;
      let event;
      try { event = JSON.parse(data); } catch { continue; }
      if (event && typeof event === 'object') onEvent(event);
    }
  }
}

/**
 * Hermes Agent through its gateway API server Runs API (default http://127.0.0.1:8642).
 * Primary reference: website/docs/user-guide/features/api-server.md in NousResearch/hermes-agent.
 *   POST /v1/runs {input, session_id, instructions} + Idempotency-Key  -> {run_id}
 *   GET  /v1/runs/{id}/events   SSE: message.delta, message.interim, tool.started,
 *        tool.completed, subagent.start/complete, approval.request, approval.responded,
 *        run.completed | run.failed | run.cancelled | run.interrupted
 *   POST /v1/runs/{id}/approval {choice: once|deny, request_id}
 *   POST /v1/runs/{id}/stop
 *   GET  /v1/capabilities, GET /v1/runs/{id}
 * Hermes runs tools on its own host under its own approval configuration
 * (~/.hermes/config.yaml), so the companion's approved folders are advisory here.
 */
export class HermesRuntime extends Runtime {
  static id = 'hermes';
  static displayName = 'Hermes';

  constructor({ url = null, token = null, fetch = globalThis.fetch, pollInterval = 1000, requestTimeout = 15000, readEnvironment = readHermesEnvironment } = {}) {
    super();
    this.configuredURL = url; this.token = token; this.fetch = fetch; this.pollInterval = pollInterval;
    this.requestTimeout = requestTimeout; this.readEnvironment = readEnvironment;
    this.features = { approvals: false, cancel: false, runStatus: false, idempotency: false };
    this.threadId = null; this.turnId = null; this.active = false; this.lastRunId = null;
    this.output = ''; this.pending = new Map(); this.controller = null; this.pollTimer = null; this.closed = false;
  }
  get capabilities() { return { approvals: this.features.approvals, folderScope: false, modelRouting: false, cancel: this.features.cancel }; }

  async start(cwd, { saved = {}, permissions, instructions }) {
    this.cwd = cwd; this.permissions = permissions;
    const environment = (!this.token || !(this.configuredURL ?? saved.url)) ? await this.readEnvironment() : {};
    const host = environment.API_SERVER_HOST && !['0.0.0.0', '::'].includes(environment.API_SERVER_HOST) ? environment.API_SERVER_HOST : '127.0.0.1';
    this.url = hermesURL(this.configuredURL ?? saved.url ?? `http://${host.includes(':') ? `[${host}]` : host}:${environment.API_SERVER_PORT || 8642}`);
    this.token ??= environment.API_SERVER_KEY || null;
    if (!this.token) throw new Error('No Hermes API server key. Set API_SERVER_ENABLED=true and API_SERVER_KEY in ~/.hermes/.env and restart `hermes gateway`, or start the companion with --runtime-token-file.');
    this.instructions = `${instructions}\n\nWorkspace:\n- The assistant's workspace folder is ${cwd}. Use it for files you create unless the user names another location.`;
    const capabilities = await this.request('GET', '/v1/capabilities');
    const features = capabilities?.features ?? {};
    if (!features.run_submission || !features.run_events_sse) throw new Error('This Hermes version does not offer the Runs API with event streaming. Update Hermes Agent (`hermes update`).');
    // The published docs name the approval flag `run_approval`; the server sends
    // `run_approval_response` plus `approval_events`. Accept any of them.
    this.features = {
      approvals: Boolean(features.run_approval_response || features.run_approval || features.approval_events),
      cancel: Boolean(features.run_stop), runStatus: Boolean(features.run_status),
      idempotency: Boolean(features.runs_idempotency?.supported ?? features.runs_idempotency),
    };
    this.threadId = saved.threadId ?? newSessionId();
    this.lastRunId = typeof saved.lastRunId === 'string' ? saved.lastRunId : null;
    let lastTurn = null;
    if (saved.threadId && this.lastRunId && this.features.runStatus) {
      const run = await this.request('GET', `/v1/runs/${encodeURIComponent(this.lastRunId)}`, undefined, { allowMissing: true });
      if (run) {
        const status = TERMINAL_STATUS[run.status];
        lastTurn = { turnId: this.lastRunId, status: status === 'completed' ? 'idle' : status === 'cancelled' ? 'interrupted' : status ?? 'running', output: bounded(run.output ?? '', 65536), error: run.error ?? null };
        // A run still executing after a companion restart can only be observed by polling.
        if (!status) { this.turnId = this.lastRunId; this.active = true; this.poll(this.lastRunId); }
      }
    }
    return { threadId: this.threadId, lastTurn };
  }
  async submit(text, { requestId, beforeSend = async () => {} }) {
    await beforeSend({ route: null });
    this.output = ''; this.turnId = null; this.active = true; this.pending.clear();
    try {
      const body = { input: text, session_id: this.threadId, instructions: this.instructions };
      // Hermes durably deduplicates this key, so an uncertain POST can never start a second run.
      const run = await this.request('POST', '/v1/runs', body, { headers: requestId ? { 'Idempotency-Key': `brainkit-${requestId}` } : {} });
      if (typeof run?.run_id !== 'string') throw new Error('Hermes did not return a run ID');
      this.turnId = run.run_id; this.lastRunId = run.run_id;
      this.subscribe(run.run_id);
      return { turnId: run.run_id };
    } catch (error) {
      this.active = false;
      throw error;
    }
  }
  async subscribe(runId) {
    this.controller?.abort();
    const controller = this.controller = new AbortController();
    let response;
    try {
      response = await this.fetch(`${this.url}/v1/runs/${encodeURIComponent(runId)}/events`, { headers: { Authorization: `Bearer ${this.token}`, Accept: 'text/event-stream' }, signal: controller.signal, redirect: 'error' });
      if (!response.ok) throw new Error(`Hermes events returned ${response.status}`);
      await readEvents(response.body, event => this.onEvent(event));
    } catch (error) {
      if (controller.signal.aborted || this.closed) return;
      this.emit('notice', { error: `Hermes event stream: ${bounded(error.message, 512)}` });
    }
    // The stream closed without a terminal event (network loss, gateway restart):
    // Hermes forgets the transport, so the run's status endpoint is the only truth left.
    if (this.active && this.turnId === runId && !controller.signal.aborted && !this.closed) this.poll(runId);
  }
  poll(runId) {
    if (!this.features.runStatus) { this.finish(runId, 'failed', { error: 'Lost the Hermes event stream and this Hermes version cannot report run status' }); return; }
    clearTimeout(this.pollTimer);
    this.pollTimer = setTimeout(async () => {
      if (!this.active || this.turnId !== runId || this.closed) return;
      try {
        const run = await this.request('GET', `/v1/runs/${encodeURIComponent(runId)}`, undefined, { allowMissing: true });
        if (!run) return this.finish(runId, 'failed', { error: 'Hermes no longer knows this run' });
        if (run.status === 'waiting_for_approval' && run.approval) this.onEvent({ ...run.approval, event: 'approval.request', run_id: runId });
        const status = TERMINAL_STATUS[run.status];
        if (status) return this.finish(runId, status, { output: run.output, error: run.error });
      } catch (error) { this.emit('notice', { error: bounded(error.message, 512) }); }
      this.poll(runId);
    }, this.pollInterval);
    this.pollTimer.unref?.();
  }
  onEvent(event) {
    const runId = event.run_id;
    if (!this.active || runId !== this.turnId) return;
    switch (event.event) {
      case 'message.delta':
        if (typeof event.delta === 'string') { this.output = bounded(this.output + event.delta, 65536); this.emit('output', { turnId: runId, text: this.output }); }
        break;
      case 'message.interim':
        if (!event.already_streamed && event.text) this.emit('progress', { turnId: runId, text: bounded(event.text, 1024) });
        break;
      case 'tool.started':
        this.emit('progress', { turnId: runId, text: bounded(event.preview ? `${event.tool}: ${event.preview}` : event.tool || 'Working', 1024) });
        break;
      case 'tool.completed':
        this.emit('progress', { turnId: runId, text: bounded(`${event.tool || 'Tool'} ${event.error ? 'failed' : 'finished'}`, 1024) });
        break;
      case 'subagent.start':
        this.emit('progress', { turnId: runId, text: bounded(event.goal ? `Delegating: ${event.goal}` : 'Delegating to a subagent', 1024) });
        break;
      case 'subagent.complete':
        this.emit('progress', { turnId: runId, text: bounded(`Subagent ${event.status || 'finished'}`, 1024) });
        break;
      case 'approval.request': {
        const id = typeof event.request_id === 'string' && event.request_id ? event.request_id : null;
        if (id && this.pending.has(id)) break;
        if (!this.features.approvals || !id) {
          // Without a precise request ID a decision could land on a different action: refuse.
          this.post(`/v1/runs/${encodeURIComponent(runId)}/approval`, { choice: 'deny', ...(id ? { request_id: id } : {}) });
          this.emit('progress', { turnId: runId, text: 'Unsupported approval request was denied' });
          break;
        }
        this.pending.set(id, runId);
        this.emit('approval', { id, turnId: runId, kind: 'command', reason: event.description || 'Hermes asks to run a command', command: event.command ?? null, cwd: null });
        break;
      }
      default: {
        const status = TERMINAL[event.event];
        if (status) this.finish(runId, status, { output: event.output, error: event.error ?? event.turn_exit_reason });
      }
    }
  }
  finish(runId, status, { output, error } = {}) {
    if (!this.active || runId !== this.turnId) return;
    // Hermes withdraws unanswered approvals itself when a run ends.
    this.active = false; this.pending.clear(); clearTimeout(this.pollTimer); this.controller?.abort(); this.controller = null;
    const text = typeof output === 'string' && output ? bounded(output, 65536) : this.output;
    this.emit(status, { turnId: runId, output: text, error: status === 'completed' ? null : (error ? String(error) : status === 'failed' ? 'Hermes run failed' : null) });
  }
  approve(id, decision) {
    const runId = this.pending.get(id);
    if (!runId) throw Object.assign(new Error('Approval is no longer pending'), { status: 409 });
    this.pending.delete(id);
    // `once` is a single action; the session/always scopes Hermes offers are never sent.
    this.post(`/v1/runs/${encodeURIComponent(runId)}/approval`, { choice: decision === 'accept' ? 'once' : 'deny', request_id: id });
  }
  post(route, body) {
    this.request('POST', route, body).catch(error => this.emit('notice', { error: `Hermes approval: ${bounded(error.message, 512)}` }));
  }
  async setPermissions(permissions) { this.permissions = permissions; }
  async cancel(turnId) {
    if (!this.features.cancel) throw Object.assign(new Error('This Hermes version cannot stop a run'), { status: 409 });
    await this.request('POST', `/v1/runs/${encodeURIComponent(turnId)}/stop`, {});
  }
  async reset() {
    this.threadId = newSessionId(); this.turnId = null; this.lastRunId = null; this.active = false; this.output = '';
    return { threadId: this.threadId };
  }
  persistentState() { return { url: this.url ?? this.configuredURL ?? null, lastRunId: this.lastRunId }; }
  close() { this.closed = true; this.controller?.abort(); clearTimeout(this.pollTimer); }

  async request(method, route, body, { headers = {}, allowMissing = false } = {}) {
    let response;
    try {
      response = await this.fetch(this.url + route, {
        method, redirect: 'error', signal: AbortSignal.timeout(this.requestTimeout),
        headers: { Authorization: `Bearer ${this.token}`, Accept: 'application/json', ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}), ...headers },
        ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
      });
    } catch (error) {
      throw new Error(`Hermes is not reachable at ${this.url} (${error.cause?.code ?? error.name}). Start it with \`hermes gateway\` and API_SERVER_ENABLED=true.`);
    }
    const text = await response.text();
    let value = null;
    try { value = text ? JSON.parse(text) : null; } catch { /* reported below */ }
    if (allowMissing && response.status === 404) return null;
    if (response.status === 401 || response.status === 403) throw new Error('Hermes rejected the API server key');
    if (!response.ok) throw Object.assign(new Error(`Hermes ${response.status}: ${bounded(value?.error?.message ?? value?.error ?? text, 512)}`), { status: response.status === 409 ? 409 : 502 });
    return value;
  }
}

function newSessionId() { return `brainkit-${randomUUID()}`; }
