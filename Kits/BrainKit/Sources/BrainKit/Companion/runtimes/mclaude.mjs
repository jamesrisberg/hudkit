import { execFile } from 'node:child_process';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { access, readdir, readFile, symlink, unlink } from 'node:fs/promises';
import net from 'node:net';
import { homedir } from 'node:os';
import path from 'node:path';
import { Runtime, bounded } from './Runtime.mjs';
import { describe } from './claude.mjs';
import { allowedToolPatterns, claudeMcpServers } from '../tool-servers.mjs';

/** Every session this runtime starts is named and tagged `brainkit-<hex>`, so it is recognisable in MechaHUD and tmux. */
export const TAG_PREFIX = 'brainkit-';
// A companion started from inside a Claude Code session inherits these; a launched session must not.
const SEED_ENVIRONMENT = ['CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SESSION_ID', 'CLAUDE_CODE_CHILD_SESSION',
  'CLAUDE_CODE_REMOTE_SESSION_ID', 'CLAUDE_CODE_SESSION_ATTENDED', 'CLAUDE_CODE_MESSAGING_SOCKET', 'CLAUDE_CODE_MESSAGING_TOKEN',
  'CLAUDE_CODE_EXECPATH', 'CLAUDE_PID', 'MCLAUDE_SPAWN_TAG'];
const TRUST_OPTION = /trust this folder/i;

/** mechaclaude's launch failure (the wrapper prints `<name>: <reason>`) as a sentence to show. */
export function mclaudeFailure(stderr) {
  const line = String(stderr ?? '').trim().split('\n').filter(Boolean).at(-1) ?? '';
  const reason = line.replace(/^[\w.-]+: /, '');
  if (/requires tmux/.test(reason)) return 'mclaude sessions need tmux: brew install tmux';
  return `mclaude could not start a session: ${bounded(reason || 'no reason given', 512)}`;
}

/**
 * A mechaclaude session: an interactive Claude Code instrumented by mechaclaude, running
 * detached so MechaHUD's dashboard shows and drives the same session. mechaclaude owns the
 * launch (the `mclaude` wrapper's `--mc-detach` mode, including its tmux dependency); this
 * runtime only talks to the session's hub socket (mechaclaude PROTOCOL.md):
 *
 *   launch   mclaude --mc-detach --mc-name <tag> --mc-cwd <workspace> --mc-tag <tag>
 *                    --append-system-prompt <voice instructions + host context>
 *                    [--mcp-config <tool servers> [--allowedTools mcp__<server>__* ...]]
 *                    --permission-mode acceptEdits|bypassPermissions [--add-dir ...] [--resume <id>]
 *            -> "name=<tag> pid=<pid> ver=<v> tag=<tag>"; the session's sidecar
 *            <state-taps>/cc-<pid>.meta.json carries spawnTag, sessionId and sock
 *   read     NDJSON frames on the socket: affordances.busy, the `turn` view's loading and
 *            session_state for busy; stream_event text deltas of the main conversation
 *            (querySource repl_main_thread) for live text; transcript `message` records for
 *            the committed answer and turn end; `dialog` + `overlay` for permission prompts;
 *            turn_pulse `aborted` for interruption; `sid` for a new session id
 *   control  {type:"control", action, cid}: affordances (query), submit {text},
 *            choose {index} (the permission select), answer {id, result}, interrupt
 *   end      SIGTERM to the session's own pid, mechaclaude's force-exit (the tmux session
 *            closes with it)
 *
 * The session outlives the companion: a restart finds it again by its tag. Turns started
 * from another client (MechaHUD, the terminal) are mirrored as turns without a request id,
 * and approvals answered there are withdrawn with `approvalResolved`.
 */
export class MclaudeRuntime extends Runtime {
  static id = 'mclaude';
  static displayName = 'mclaude';

  constructor({ executable = 'mclaude', toolServers = [], stateDirectory = null, env = process.env, startTimeout = 30000, readyTimeout = 60000,
    ackTimeout = 60000, settleMs = 1200, killTimeout = 5000, pollInterval = 300 } = {}) {
    super();
    this.executable = executable; this.baseEnv = env; this.toolServers = toolServers;
    this.stateDirectory = stateDirectory ?? env.MCLAUDE_STATE_DIR ?? path.join(homedir(), '.claude', 'state-taps');
    Object.assign(this, { startTimeout, readyTimeout, ackTimeout, settleMs, killTimeout, pollInterval });
    this.connection = null; this.meta = null; this.tag = null; this.sessionId = null; this.launchPermissions = null; this.launchOptions = null;
    this.turn = null; this.approvals = new Map(); this.closed = false; this.ready = false; this.clearing = false;
    this.resetView();
  }
  get capabilities() { return { approvals: true, folderScope: true, modelRouting: false, cancel: true }; }
  get supportsToolServers() { return true; }

  resetView() { this.affordances = null; this.loading = false; this.sessionState = null; this.dialogs = []; this.overlay = null; }
  /** From here on the session's state drives turns and approvals. */
  activate() {
    if (!this.connection || this.closed) return;
    this.ready = true;
    this.syncApprovals(); this.evaluate();
  }

  async start(cwd, { saved = {}, permissions, instructions }) {
    this.cwd = cwd; this.permissions = permissions; this.instructions = instructions;
    const live = typeof saved.tag === 'string' && saved.tag.startsWith(TAG_PREFIX) ? await this.findSession(saved.tag) : null;
    let lastTurn = null;
    if (live) {
      this.tag = saved.tag; this.launchPermissions = saved.launchPermissions ?? null;
      this.launchOptions = typeof saved.launchOptions === 'string' ? saved.launchOptions : null;
      await this.attach(live, { launched: false });
      // A session started with other permissions, instructions or tool servers resumes its
      // conversation under the new ones, unless it is in the middle of a turn: that is never cut off.
      const changed = !samePermissions(this.launchPermissions, permissions) || this.launchOptions !== this.optionsFingerprint();
      if (changed && !this.busy) await this.relaunch();
      else if (this.busy) { this.beginTurn({ external: true, confirmed: true }); lastTurn = { turnId: this.turn.id, status: 'running', output: '', error: null }; }
    } else {
      await this.launch();
    }
    // Session applies the start result first; approvals emitted before that would be declined.
    setImmediate(() => this.activate());
    return { threadId: this.sessionId, lastTurn };
  }

  // MARK: Launch and attach

  environment() {
    const env = { ...this.baseEnv };
    for (const name of SEED_ENVIRONMENT) delete env[name];
    return env;
  }
  args({ tag, resume }) {
    const full = this.permissions.mode === 'fullAccess';
    const extra = this.permissions.approvedFolders.filter(folder => folder !== this.cwd);
    return ['--mc-detach', '--mc-name', tag, '--mc-cwd', this.cwd, '--mc-tag', tag,
      '--append-system-prompt', this.instructions,
      ...this.toolServerArgs(),
      '--permission-mode', full ? 'bypassPermissions' : 'acceptEdits',
      ...(resume ? ['--resume', resume] : []),
      ...(extra.length ? ['--add-dir', ...extra] : [])];
  }
  toolServerArgs() {
    if (!this.toolServers.length) return [];
    const allowed = allowedToolPatterns(this.toolServers);
    return ['--mcp-config', JSON.stringify({ mcpServers: claudeMcpServers(this.toolServers) }),
      ...(allowed.length ? ['--allowedTools', ...allowed] : [])];
  }
  /** What a launch fixes besides permissions; a reattached session launched with others is relaunched. */
  optionsFingerprint() {
    return createHash('sha256').update(JSON.stringify({ instructions: this.instructions, toolServers: this.toolServers })).digest('hex');
  }
  async launch({ resume = null } = {}) {
    const tag = TAG_PREFIX + randomBytes(6).toString('hex');
    const output = await new Promise((resolve, reject) => execFile(this.executable, this.args({ tag, resume }),
      { cwd: this.cwd, env: this.environment(), timeout: 20000 }, (error, stdout, stderr) => {
        if (!error) return resolve(String(stdout));
        if (error.code === 'ENOENT') return reject(new Error(`mclaude is not installed (${this.executable}): not found. Install mechaclaude, which puts \`mclaude\` in ~/.local/bin.`));
        reject(new Error(mclaudeFailure(stderr || error.message)));
      }));
    const handle = Object.fromEntries(output.trim().split(/\s+/).map(token => token.split('=')).filter(pair => pair.length === 2));
    const pid = Number(handle.pid) || null;
    const deadline = Date.now() + this.startTimeout;
    let meta = null;
    while (!meta && Date.now() < deadline && !this.closed) {
      meta = await this.findSession(tag, pid);
      if (!meta) await delay(150);
    }
    if (!meta) {
      if (pid) await this.endSession(pid);
      throw new Error(`The mclaude session did not start within ${Math.round(this.startTimeout / 1000)} s.`);
    }
    this.tag = tag; this.launchPermissions = this.permissions; this.launchOptions = this.optionsFingerprint();
    try { await this.attach(meta, { launched: true }); }
    catch (error) { await this.endSession(meta.pid); throw error; }
  }
  /** The live sidecar mechaclaude wrote for a session launched with this tag. */
  async findSession(tag, pid = null) {
    let names = [];
    try { names = await readdir(this.stateDirectory); } catch { return null; }
    let found = null;
    for (const name of names.filter(name => name.endsWith('.meta.json'))) {
      let meta;
      try { meta = JSON.parse(await readFile(path.join(this.stateDirectory, name), 'utf8')); } catch { continue; }
      if (meta?.spawnTag !== tag || !Number.isInteger(meta.pid) || typeof meta.sock !== 'string' || !isAlive(meta.pid)) continue;
      if (pid && meta.pid !== pid) { found ??= meta; continue; }
      return meta;
    }
    return found;
  }
  async attach(meta, { launched }) {
    this.meta = meta; this.sessionId = meta.sessionId ?? null; this.transcriptPath = null; this.resetView(); this.ready = false;
    const connection = await HubConnection.open(meta.sock);
    this.connection = connection;
    connection.on('frame', frame => this.onFrame(frame));
    connection.on('close', () => this.onClose(connection));
    try { await this.awaitReady(connection, { launched }); }
    catch (error) { if (this.connection === connection) this.detach(); throw error; }
  }
  async awaitReady(connection, { launched }) {
    // A new session is ready once it can take a message; one found again only needs to answer.
    const deadline = Date.now() + (launched ? this.readyTimeout : 10000);
    let trusted = false;
    while (!this.closed && this.connection === connection) {
      if (launched ? this.affordances?.canSubmit : this.affordances) break;
      // The folder-trust prompt of the workspace the user chose for the agent.
      const trust = this.overlay?.options?.findIndex(option => TRUST_OPTION.test(optionLabel(option))) ?? -1;
      if (launched && trust >= 0 && !trusted) { trusted = true; connection.control('choose', { index: trust }).catch(() => {}); }
      if (Date.now() > deadline) throw new Error('The mclaude session is waiting on a prompt before it can take requests. Answer it in MechaHUD or the session\'s terminal, then check the connection.');
      connection.send({ type: 'control', action: 'affordances' });
      await delay(this.pollInterval);
    }
    if (this.connection !== connection) throw new Error('The mclaude session ended while starting.');
    if (!this.sessionId) throw new Error('The mclaude session did not report its session id.');
  }
  onClose(connection) {
    if (connection !== this.connection || this.closed) return;
    this.connection = null;
    clearTimeout(this.settleTimer);
    this.turn = null; this.approvals.clear();
    this.emit('disconnected', new Error('The mclaude session ended. Check the connection to start a new one.'));
  }
  /** mechaclaude's force-exit: SIGTERM to the session's own process, SIGKILL if it does not exit. */
  async endSession(pid) {
    if (!Number.isInteger(pid) || pid <= 1 || !isAlive(pid)) return;
    try { process.kill(pid, 'SIGTERM'); } catch { return; }
    const deadline = Date.now() + this.killTimeout;
    while (Date.now() < deadline && isAlive(pid)) await delay(50);
    if (isAlive(pid)) try { process.kill(pid, 'SIGKILL'); } catch {}
  }
  detach() {
    const connection = this.connection; this.connection = null;
    connection?.close();
  }

  // MARK: Session state

  get busy() {
    return Boolean(this.affordances?.busy || this.loading || ['running', 'requires_action'].includes(this.sessionState));
  }
  permissionDialogs() {
    return this.dialogs.filter(dialog => typeof dialog?.kind === 'string' && dialog.kind.startsWith('permission_') && dialog.kind !== 'permission_ask_user_question');
  }
  onFrame(frame) {
    if (typeof frame.sessionId === 'string' && frame.sessionId && !frame.snapshot) this.sessionId = frame.sessionId;
    switch (frame.type) {
      case 'affordances': this.affordances = frame.affordances ?? null; break;
      case 'turn': this.loading = Boolean(frame.data?.loading); break;
      case 'session_state': this.sessionState = frame.state ?? null; break;
      case 'overlay': this.overlay = frame.closed ? null : frame; break;
      case 'dialog': this.dialogs = Array.isArray(frame.open) ? frame.open : []; this.syncApprovals(); break;
      case 'dialog_answer': this.dialogs = this.dialogs.filter(dialog => dialog?.id !== frame.id); this.syncApprovals(); break;
      case 'sid': this.transcriptPath = null; this.emit('sid', frame.sessionId); break;
      case 'transcript_path': if (typeof frame.path === 'string') this.transcriptPath = frame.path; break;
      case 'stream_event': this.onStream(frame); break;
      case 'message': this.onRecord(frame.message); break;
      case 'tool_state':
        if (this.turn && frame.state === 'running' && !frame.agentId && frame.name) { this.confirm(); this.progress(`Using ${frame.name}`); }
        break;
      case 'turn_pulse': if (this.turn && frame.phase === 'aborted') this.turn.aborted = true; break;
      case 'error':
        if (this.turn) { this.turn.error = bounded(frame.error?.message ?? 'Claude reported an error', 2048); this.turn.errorIsLast = true; }
        break;
      default: break;
    }
    this.evaluate();
  }
  /** Text deltas of the main conversation only; title, recap and subagent streams never commit. */
  onStream(frame) {
    const turn = this.turn;
    if (!turn || frame.agentId || (frame.querySource && !String(frame.querySource).startsWith('repl_main_thread'))) return;
    const event = frame.event ?? {};
    if (event.kind === 'message_start') { turn.live.set(frame.msgSeq, this.entry(turn, frame.msgId ?? `seq-${frame.msgSeq}`)); return; }
    if (event.kind === 'content_block_delta' && typeof event.text === 'string') {
      const entry = turn.live.get(frame.msgSeq) ?? this.entry(turn, `seq-${frame.msgSeq}`);
      turn.live.set(frame.msgSeq, entry);
      entry.text += event.text; turn.errorIsLast = false;
      this.confirm(); this.publish();
    }
  }
  onRecord(record) {
    const turn = this.turn;
    if (!turn || !record || record.isSidechain) return;
    // Records are tailed from the transcript file; anything written before this turn is history.
    const at = Date.parse(record.timestamp ?? '');
    if (Number.isFinite(at) && at < turn.startedAt - 2000) return;
    if (record.type === 'system' && record.subtype === 'turn_duration') { turn.ended = true; return; }
    if (record.type === 'user' && !record.isMeta && isPrompt(record.message?.content)) { this.confirm(); return; }
    if (record.type !== 'assistant') return;
    const message = record.message ?? {};
    const content = Array.isArray(message.content) ? message.content : [];
    const text = content.filter(block => block?.type === 'text').map(block => block.text).join('');
    if (text) {
      const entry = [...turn.entries].find(item => item.id === message.id) ?? this.entry(turn, message.id ?? randomUUID());
      entry.text = text; turn.errorIsLast = false;
      this.confirm(); this.publish();
    }
    for (const block of content.filter(block => block?.type === 'tool_use')) {
      const input = block.input ?? {};
      this.progress(block.name === 'Bash' ? input.description || input.command : input.file_path ? `${block.name} ${input.file_path}` : block.name);
    }
    if (message.stop_reason === 'end_turn') turn.ended = true;
  }
  entry(turn, id) { const entry = { id, text: '' }; turn.entries.push(entry); return entry; }
  publish() {
    const turn = this.turn;
    turn.output = bounded(turn.entries.map(entry => entry.text).filter(Boolean).join('\n\n'), 65536);
    if (turn.confirmed) this.emit('output', { turnId: turn.id, text: turn.output });
  }
  progress(text) { if (this.turn?.confirmed && text) this.emit('progress', { turnId: this.turn.id, text: bounded(text, 1024) }); }

  syncApprovals() {
    const open = this.permissionDialogs();
    const ids = new Set(open.map(dialog => dialog.id));
    // Answered here or in another client (MechaHUD, the terminal): withdraw it.
    for (const id of [...this.approvals.keys()]) if (!ids.has(id)) { this.approvals.delete(id); this.emit('approvalResolved', { id }); }
    if (!this.ready) return;
    for (const dialog of open) {
      if (this.approvals.has(dialog.id)) continue;
      if (!this.turn) this.beginTurn({ external: true });
      if (!this.turn.external && !this.turn.confirmed) continue;
      this.confirm();
      const payload = dialog.payload ?? {};
      this.approvals.set(dialog.id, { input: payload.input ?? {}, turnId: this.turn.id });
      this.emit('approval', { id: dialog.id, turnId: this.turn.id, ...describe(String(payload.toolName ?? dialog.kind), payload.input ?? {}) });
    }
    if (this.dialogs.some(dialog => dialog?.kind === 'permission_ask_user_question')) this.progress('Claude is asking a question. Answer it in MechaHUD.');
  }

  // MARK: Turns

  /**
   * A turn this runtime submitted is confirmed by the hub's ack. A turn another client
   * started (busy with no turn of ours) is confirmed only by evidence of a prompt: its user
   * record, main-conversation text, a tool starting or a permission prompt. Busy alone (a
   * hook, a background request) never replaces the last answer with an empty turn.
   */
  beginTurn({ external, confirmed = false }) {
    clearTimeout(this.settleTimer); this.settleTimer = null;
    this.turn = { id: randomUUID(), external, confirmed, startedAt: Date.now(), sawBusy: external, entries: [], live: new Map(),
      output: '', ended: false, aborted: false, cancelling: false, error: null, errorIsLast: false };
    return this.turn;
  }
  confirm() {
    const turn = this.turn;
    if (!turn || turn.confirmed || !turn.external || !this.ready) return;
    turn.confirmed = true;
    this.emit('started', { turnId: turn.id });
    this.emit('output', { turnId: turn.id, text: turn.output });
    this.emit('progress', { turnId: turn.id, text: 'Working' });
  }
  /** Decides when another client's turn begins and when any turn has ended. */
  evaluate() {
    if (!this.connection || !this.ready || this.clearing) return;
    const busy = this.busy;
    const waiting = this.permissionDialogs().length > 0;
    if (!this.turn) {
      if (busy) this.beginTurn({ external: true });
      return;
    }
    const turn = this.turn;
    if (busy || waiting) { turn.sawBusy = true; clearTimeout(this.settleTimer); this.settleTimer = null; return; }
    if (!turn.confirmed && !turn.external) return;   // our submit is still waiting for its ack
    // Idle. The record that closes the turn can trail the busy signal slightly.
    if (!turn.sawBusy && !turn.ended && Date.now() - turn.startedAt < 15000) {
      clearTimeout(this.settleTimer);
      this.settleTimer = setTimeout(() => { this.settleTimer = null; this.evaluate(); }, 500);
      return;
    }
    if (turn.confirmed && (turn.ended || turn.aborted || turn.cancelling)) return this.finish();
    if (!this.settleTimer) this.settleTimer = setTimeout(() => { this.settleTimer = null; if (this.turn === turn && !this.busy) this.finish(); }, this.settleMs);
  }
  finish() {
    const turn = this.turn;
    if (!turn) return;
    clearTimeout(this.settleTimer); this.settleTimer = null;
    this.turn = null; this.approvals.clear();
    if (!turn.confirmed) return;
    if (turn.aborted || turn.cancelling) return this.emit('cancelled', { turnId: turn.id, output: turn.output, error: null });
    if (turn.error && turn.errorIsLast) return this.emit('failed', { turnId: turn.id, output: turn.output, error: turn.error });
    this.emit('completed', { turnId: turn.id, output: turn.output, error: null });
  }
  requireConnection() {
    if (!this.connection) throw Object.assign(new Error('The mclaude session is not connected'), { status: 503 });
    return this.connection;
  }

  async submit(text, { beforeSend = async () => {} }) {
    const connection = this.requireConnection();
    if (this.turn || this.busy || this.permissionDialogs().length) throw Object.assign(new Error('The session is busy with another turn'), { status: 409 });
    if (this.dialogs.length || this.overlay) throw Object.assign(new Error('The session is waiting on a prompt. Answer it in MechaHUD.'), { status: 409 });
    await beforeSend({ route: null });
    const turn = this.beginTurn({ external: false });
    let ack;
    try { ack = await connection.control('submit', { text }, this.ackTimeout); }
    catch (error) { if (this.turn === turn) this.turn = null; throw error; }
    if (ack.status !== 'applied') {
      if (this.turn === turn) this.turn = null;
      throw new Error(`mclaude did not take the message (${ack.status}${ack.detail ? `: ${bounded(ack.detail, 256)}` : ''})`);
    }
    turn.confirmed = true;
    this.emit('started', { turnId: turn.id });
    if (turn.output) this.emit('output', { turnId: turn.id, text: turn.output });
    this.syncApprovals();
    this.evaluate();
    return { turnId: turn.id };
  }
  approve(id, decision) {
    const approval = this.approvals.get(id);
    if (!approval) throw Object.assign(new Error('Approval is no longer pending'), { status: 409 });
    const connection = this.requireConnection();
    const open = this.permissionDialogs();
    // The select overlay belongs to the prompt on screen; with one prompt open, pick its exact
    // one-time option ("yes"), never a "don't ask again" row. Otherwise answer the dialog by id.
    const index = this.overlay?.options?.findIndex(option => option?.value === (decision === 'accept' ? 'yes' : 'no')) ?? -1;
    const request = open.length === 1 && open[0].id === id && index >= 0
      ? connection.control('choose', { index })
      : connection.control('answer', { id, result: decision === 'accept' ? { behavior: 'allow', updatedInput: approval.input } : { behavior: 'deny', message: 'The user denied this action. Do not try another way around it.' } });
    request.then(ack => { if (ack.status !== 'applied') this.emit('notice', { error: `mclaude did not take the answer (${ack.status}${ack.detail ? `: ${bounded(ack.detail, 256)}` : ''})` }); })
      .catch(error => this.emit('notice', { error: bounded(error.message, 512) }));
  }
  async cancel(turnId) {
    const connection = this.requireConnection();
    if (!this.turn || this.turn.id !== turnId || !this.turn.confirmed) throw Object.assign(new Error('No interruptible turn is active'), { status: 409 });
    this.turn.cancelling = true;
    const ack = await connection.control('interrupt', {}, 10000);
    if (ack.status !== 'applied') { if (this.turn) this.turn.cancelling = false; throw Object.assign(new Error(`mclaude could not interrupt (${ack.status})`), { status: 409 }); }
  }
  /** New conversation: `/clear` in the same session, which gives it a new session id. */
  async reset() {
    const connection = this.requireConnection();
    const before = this.sessionId;
    // `/clear` is not a turn; keep it from being mirrored as one.
    this.clearing = true;
    try { return await this.clear(connection, before); }
    finally { this.clearing = false; this.turn = null; }
  }
  async clear(connection, before) {
    const changed = new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.off('sid', onSid); reject(new Error('The mclaude session did not start a new conversation')); }, 15000);
      const onSid = id => { if (id && id !== before) { clearTimeout(timer); this.off('sid', onSid); resolve(id); } };
      this.on('sid', onSid);
    });
    const ack = await connection.control('submit', { text: '/clear' }, this.ackTimeout);
    if (ack.status !== 'applied') throw new Error(`mclaude did not clear the conversation (${ack.status})`);
    this.sessionId = await changed;
    for (let waited = 0; this.busy && waited < 3000; waited += 50) await delay(50);
    return { threadId: this.sessionId };
  }
  /** Folder scope and permission mode are launch options, so a change relaunches the session on its conversation. */
  async setPermissions(permissions) {
    this.permissions = permissions;
    if (!this.meta || samePermissions(this.launchPermissions, permissions)) return;
    await this.relaunch();
    this.activate();
  }
  async relaunch() {
    const { pid } = this.meta;
    // A conversation exists on disk once its first turn ran; an empty one is simply started anew.
    const resume = await this.resumableSession();
    this.detach(); this.resetView();
    await this.endSession(pid);
    await this.launch({ resume });
  }
  async resumableSession() {
    if (!this.sessionId || !this.transcriptPath) return null;
    try { await access(this.transcriptPath); return this.sessionId; } catch { return null; }
  }
  snapshot() { return { ...super.snapshot(), sessionKey: this.sessionId ? `claude:${this.sessionId}` : null }; }
  persistentState() { return { tag: this.tag, launchPermissions: this.launchPermissions, launchOptions: this.launchOptions }; }
  /** Leaves the session running for MechaHUD and the next start. */
  close() { this.closed = true; clearTimeout(this.settleTimer); this.detach(); }
}

/** One NDJSON connection to a session's hub socket, with acknowledged controls. */
class HubConnection {
  static async open(sock) {
    // macOS limits socket paths to 104 bytes; a longer one is reached through a short symlink.
    let target = sock; let link = null;
    if (Buffer.byteLength(sock) > 100) {
      link = path.join('/tmp', `bk-mc-${process.pid.toString(36)}-${randomBytes(4).toString('hex')}`);
      await symlink(sock, link); target = link;
    }
    const socket = net.connect(target);
    try {
      await new Promise((resolve, reject) => { socket.once('connect', resolve); socket.once('error', reject); });
    } finally { if (link) unlink(link).catch(() => {}); }
    return new HubConnection(socket);
  }
  constructor(socket) {
    this.socket = socket; this.handlers = { frame: [], close: [] }; this.acks = new Map(); this.buffer = '';
    socket.setEncoding('utf8');
    socket.on('data', chunk => this.onData(chunk));
    socket.on('error', () => {});
    socket.on('close', () => {
      for (const { reject, timer } of this.acks.values()) { clearTimeout(timer); reject(Object.assign(new Error('The mclaude session closed'), { status: 503 })); }
      this.acks.clear();
      for (const handler of this.handlers.close) handler();
    });
  }
  on(name, handler) { this.handlers[name].push(handler); }
  onData(chunk) {
    this.buffer += chunk;
    if (this.buffer.length > 16 * 1024 * 1024) { this.socket.destroy(); return; }
    let newline;
    while ((newline = this.buffer.indexOf('\n')) >= 0) {
      const line = this.buffer.slice(0, newline); this.buffer = this.buffer.slice(newline + 1);
      if (!line) continue;
      let frame; try { frame = JSON.parse(line); } catch { continue; }
      if (!frame || typeof frame !== 'object') continue;
      if (frame.type === 'ack' && this.acks.has(frame.cid)) {
        const { resolve, timer } = this.acks.get(frame.cid); this.acks.delete(frame.cid); clearTimeout(timer); resolve(frame);
      }
      for (const handler of this.handlers.frame) handler(frame);
    }
  }
  send(frame) { if (!this.socket.destroyed) this.socket.write(JSON.stringify(frame) + '\n'); }
  /** Resolves with the hub's `ack` ({status: applied|noop|error|...}); the session applies a control only on `applied`. */
  control(action, fields = {}, timeout = 10000) {
    const cid = `bk${randomBytes(4).toString('hex')}`;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.acks.delete(cid); reject(new Error(`mclaude did not acknowledge ${action} within ${Math.round(timeout / 1000)} s`)); }, timeout);
      this.acks.set(cid, { resolve, reject, timer });
      this.send({ type: 'control', action, cid, ...fields });
    });
  }
  close() { this.socket.destroy(); }
}

/** A user record the person typed (text), not a tool result. */
function isPrompt(content) {
  if (typeof content === 'string') return content.trim().length > 0;
  return Array.isArray(content) && content.some(block => block?.type === 'text' && block.text?.trim());
}
function samePermissions(a, b) {
  return Boolean(a && b) && a.mode === b.mode && JSON.stringify(a.approvedFolders) === JSON.stringify(b.approvedFolders);
}
/** Signal 0 only probes; EPERM means alive but not ours. */
function isAlive(pid) {
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; }
}
/** Overlay labels can be projected React elements; take their text. */
function optionLabel(option) {
  const label = option?.label;
  if (typeof label === 'string') return label;
  return JSON.stringify(label ?? option?.value ?? '');
}
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
