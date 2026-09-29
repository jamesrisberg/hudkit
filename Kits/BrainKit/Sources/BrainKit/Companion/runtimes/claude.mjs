import { spawn, execFile } from 'node:child_process';
import { randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import net from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Runtime, bounded } from './Runtime.mjs';
import { allowedToolPatterns, claudeMcpServers } from '../tool-servers.mjs';

const MCP_SERVER = fileURLToPath(new URL('./claude-permission-mcp.mjs', import.meta.url));
const MCP_NAME = 'brainkit_permissions';
export const PERMISSION_TOOL = `mcp__${MCP_NAME}__approve`;
const FILE_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit']);

/**
 * Claude Code headless mode as one child process per turn:
 *   claude -p --input-format stream-json --output-format stream-json --verbose
 *          --include-partial-messages (--session-id <new uuid> | --resume <uuid>)
 *          --permission-mode acceptEdits|bypassPermissions [--add-dir ...]
 *          --mcp-config <bridge + tool servers> [--allowedTools mcp__<server>__* ...]
 *          --permission-prompt-tool mcp__brainkit_permissions__approve
 * Permission prompts reach the companion through claude-permission-mcp.mjs, which
 * Claude Code launches as an MCP stdio server and which connects back over a private
 * Unix socket. Tool servers join the bridge in the same `--mcp-config`; those that do not
 * require approval are pre-allowed with `--allowedTools`, the others ask like any tool.
 * Cancellation sends SIGINT, which ends the turn and records it.
 * References: https://code.claude.com/docs/en/headless, https://code.claude.com/docs/en/cli-reference
 */
export class ClaudeRuntime extends Runtime {
  static id = 'claude';
  static displayName = 'Claude';

  constructor({ executable = 'claude', killGrace = 5000, env = process.env, toolServers = [] } = {}) {
    super();
    this.executable = executable; this.killGrace = killGrace; this.baseEnv = env; this.toolServers = toolServers;
    this.threadId = null; this.sessionStarted = false; this.turnId = null; this.active = false;
    this.child = null; this.pending = new Map(); this.bridge = null; this.bridgeToken = randomBytes(32).toString('hex');
  }
  get capabilities() { return { approvals: true, folderScope: true, modelRouting: false, cancel: true }; }
  get supportsToolServers() { return true; }

  async start(cwd, { saved = {}, permissions, instructions }) {
    this.cwd = cwd; this.permissions = permissions; this.instructions = instructions;
    await new Promise((resolve, reject) => execFile(this.executable, ['--version'], { timeout: 15000, env: this.env() }, error => error
      ? reject(new Error(`Claude Code CLI is not available (${this.executable}): ${bounded(error.code === 'ENOENT' ? 'not found' : error.message, 256)}. Install it and sign in with \`claude\`.`))
      : resolve()));
    await this.openBridge();
    this.threadId = saved.threadId && /^[0-9a-f-]{36}$/i.test(saved.threadId) ? saved.threadId : randomUUID();
    this.sessionStarted = Boolean(saved.threadId && saved.sessionStarted);
    return { threadId: this.threadId, lastTurn: null };
  }
  /** Private Unix socket in a 0700 temp directory; each connection carries one permission request. */
  async openBridge() {
    let base = tmpdir();
    // macOS limits socket paths to 104 bytes.
    if (base.length > 60) base = '/tmp';
    this.bridgeDirectory = await mkdtemp(path.join(base, 'brainkit-'));
    this.socketPath = path.join(this.bridgeDirectory, 'approval.sock');
    this.bridge = net.createServer(socket => this.onBridgeConnection(socket));
    await new Promise((resolve, reject) => { this.bridge.once('error', reject); this.bridge.listen(this.socketPath, resolve); });
  }
  onBridgeConnection(socket) {
    socket.setEncoding('utf8');
    let buffer = '';
    const answer = decision => { if (!socket.destroyed) socket.end(JSON.stringify(decision) + '\n'); };
    socket.on('error', () => {});
    socket.on('data', chunk => {
      if (buffer === null) return;
      buffer += chunk;
      if (buffer.length > 1024 * 1024) { buffer = null; return socket.destroy(); }
      const newline = buffer.indexOf('\n');
      if (newline < 0) return;
      let request;
      try { request = JSON.parse(buffer.slice(0, newline)); } catch { request = null; }
      buffer = null;
      const supplied = Buffer.from(String(request?.token ?? '')); const expected = Buffer.from(this.bridgeToken);
      if (!request || supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) return socket.destroy();
      if (!this.active || !this.turnId || typeof request.tool_name !== 'string' || !request.input || typeof request.input !== 'object' || this.pending.size >= 8)
        return answer({ behavior: 'deny', message: 'No request is waiting for this action.' });
      const id = randomUUID(); const turnId = this.turnId;
      this.pending.set(id, { socket, input: request.input, answer });
      socket.on('close', () => this.pending.delete(id));
      this.emit('approval', { id, turnId, ...describe(request.tool_name, request.input) });
    });
  }
  env() {
    const env = { ...this.baseEnv };
    // A companion started from inside a Claude Code session must not look nested.
    delete env.CLAUDECODE;
    return env;
  }
  args() {
    const full = this.permissions.mode === 'fullAccess';
    const extra = this.permissions.approvedFolders.filter(folder => folder !== this.cwd);
    const mcp = { mcpServers: { [MCP_NAME]: { type: 'stdio', command: process.execPath, args: [MCP_SERVER], env: { BRAINKIT_APPROVAL_SOCKET: this.socketPath } }, ...claudeMcpServers(this.toolServers) } };
    const allowed = allowedToolPatterns(this.toolServers);
    return ['-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose', '--include-partial-messages',
      '--append-system-prompt', this.instructions,
      '--permission-mode', full ? 'bypassPermissions' : 'acceptEdits',
      ...(extra.length ? ['--add-dir', ...extra] : []),
      '--mcp-config', JSON.stringify(mcp), ...(allowed.length ? ['--allowedTools', ...allowed] : []),
      '--permission-prompt-tool', PERMISSION_TOOL,
      ...(this.sessionStarted ? ['--resume', this.threadId] : ['--session-id', this.threadId])];
  }
  async submit(text, { beforeSend = async () => {} }) {
    await beforeSend({ route: null });
    const turnId = randomUUID();
    this.turnId = turnId; this.active = true; this.cancelling = false; this.output = ''; this.committed = ''; this.messageText = ''; this.sawDelta = false;
    let child;
    try {
      // The bridge token travels in the environment, never in argv (visible in ps).
      child = spawn(this.executable, this.args(), { cwd: this.cwd, stdio: ['pipe', 'pipe', 'pipe'], env: { ...this.env(), BRAINKIT_APPROVAL_TOKEN: this.bridgeToken } });
    } catch (error) { this.active = false; throw error; }
    this.child = child;
    let stdout = ''; let stderr = ''; let finished = false;
    const end = (status, fields) => {
      if (finished) return; finished = true;
      this.finish(turnId, status, fields);
    };
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => {
      stdout += chunk;
      if (stdout.length > 8 * 1024 * 1024) { end('failed', { error: 'Claude output exceeded size limit' }); child.kill('SIGTERM'); return; }
      let newline;
      while ((newline = stdout.indexOf('\n')) >= 0) {
        const line = stdout.slice(0, newline); stdout = stdout.slice(newline + 1);
        if (!line.trim()) continue;
        let message; try { message = JSON.parse(line); } catch { continue; }
        const result = this.onMessage(turnId, message);
        if (result) { end(result.status, result); child.stdin.end(); }
      }
    });
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', chunk => { stderr = (stderr + chunk).slice(-4096); });
    child.stdin.on('error', () => {});
    child.on('error', error => end('failed', { error: `Claude Code could not start: ${error.message}` }));
    child.on('exit', (code, signal) => {
      clearTimeout(this.killTimer);
      if (this.child === child) this.child = null;
      if (this.cancelling) end('cancelled', {});
      else end('failed', { error: bounded(stderr.trim() || `Claude Code exited (${signal ?? code}) without a result`, 2048) });
    });
    child.stdin.write(JSON.stringify({ type: 'user', message: { role: 'user', content: text } }) + '\n');
    return { turnId };
  }
  /** Maps one stream-json message; returns a terminal result or null. */
  onMessage(turnId, message) {
    if (message.type === 'system' && message.subtype === 'init') {
      if (message.session_id === this.threadId) this.sessionStarted = true;
      this.emit('started', { turnId });
      return null;
    }
    if (message.type === 'system' && message.subtype === 'api_retry') { this.emit('progress', { turnId, text: `Retrying the model request (attempt ${message.attempt ?? '?'})` }); return null; }
    // Subagent traffic carries parent_tool_use_id; only the main conversation is spoken.
    if (message.parent_tool_use_id) return null;
    if (message.type === 'stream_event') {
      const event = message.event ?? {};
      if (event.type === 'message_start') { this.messageText = ''; }
      if (event.type === 'content_block_delta' && event.delta?.type === 'text_delta' && typeof event.delta.text === 'string') {
        this.sawDelta = true; this.messageText += event.delta.text;
        this.publish();
      }
      return null;
    }
    if (message.type === 'assistant') {
      const content = Array.isArray(message.message?.content) ? message.message.content : [];
      const text = content.filter(block => block.type === 'text').map(block => block.text).join('');
      if (text) { this.messageText = text; this.publish(true); }
      for (const block of content.filter(block => block.type === 'tool_use')) {
        const input = block.input ?? {};
        this.emit('progress', { turnId, text: bounded(block.name === 'Bash' ? input.description || input.command : input.file_path ? `${block.name} ${input.file_path}` : block.name, 1024) });
      }
      return null;
    }
    if (message.type === 'result') {
      const output = typeof message.result === 'string' && message.result ? message.result : this.output;
      if (this.cancelling) return { status: 'cancelled', output };
      if (message.subtype === 'success' && !message.is_error) return { status: 'completed', output };
      return { status: 'failed', output: this.output, error: bounded(typeof message.result === 'string' && message.result ? message.result : `Claude run ended: ${message.subtype ?? 'error'}`, 2048) };
    }
    return null;
  }
  /** Visible text is every main-conversation assistant message so far, one paragraph each. */
  publish(complete = false) {
    const text = [this.committed, this.messageText].filter(Boolean).join('\n\n');
    this.output = bounded(text, 65536);
    if (complete) { this.committed = this.output; this.messageText = ''; }
    this.emit('output', { turnId: this.turnId, text: this.output });
  }
  finish(turnId, status, { output, error } = {}) {
    if (this.turnId !== turnId || !this.active) return;
    this.active = false; this.committed = '';
    for (const { answer } of this.pending.values()) answer({ behavior: 'deny', message: 'The turn ended before the user answered.' });
    this.pending.clear();
    this.emit(status, { turnId, output: output || this.output, error: error ?? null });
  }
  approve(id, decision) {
    const pending = this.pending.get(id);
    if (!pending) throw Object.assign(new Error('Approval is no longer pending'), { status: 409 });
    this.pending.delete(id);
    // Allow exactly this call with its original input; never persist a permission rule.
    pending.answer(decision === 'accept' ? { behavior: 'allow', updatedInput: pending.input } : { behavior: 'deny', message: 'The user denied this action. Do not try another way around it.' });
  }
  async setPermissions(permissions) { this.permissions = permissions; }
  async cancel(turnId) {
    const child = this.child;
    if (!child || turnId !== this.turnId || !this.active) throw Object.assign(new Error('No interruptible turn is active'), { status: 409 });
    this.cancelling = true;
    for (const [id] of this.pending) this.approve(id, 'decline');
    // SIGINT ends the turn and records it; SIGTERM follows if Claude does not exit.
    child.kill('SIGINT');
    clearTimeout(this.killTimer);
    this.killTimer = setTimeout(() => child.kill('SIGTERM'), this.killGrace);
    this.killTimer.unref?.();
  }
  async reset() {
    this.threadId = randomUUID(); this.sessionStarted = false; this.turnId = null;
    return { threadId: this.threadId };
  }
  persistentState() { return { sessionStarted: this.sessionStarted }; }
  close() {
    this.child?.kill('SIGTERM');
    this.bridge?.close();
    if (this.bridgeDirectory) rm(this.bridgeDirectory, { recursive: true, force: true }).catch(() => {});
  }
}

/** A permission request as the approval fields the app speaks and shows. */
export function describe(toolName, input) {
  if (toolName === 'Bash') return { kind: 'command', reason: bounded(input.description || 'Claude asks to run a command'), command: bounded(input.command ?? ''), cwd: null };
  if (FILE_TOOLS.has(toolName)) return { kind: 'tool', reason: bounded(`${toolName === 'Write' ? 'Write' : 'Edit'} ${input.file_path ?? input.notebook_path ?? 'a file'}`), command: null, cwd: null };
  return { kind: 'tool', reason: bounded(`Claude asks to use ${toolName}`), command: bounded(JSON.stringify(input), 2048), cwd: null };
}
