import test from 'node:test';
import assert from 'node:assert/strict';
import { chmod, cp, mkdir, mkdtemp, realpath, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Session } from '../session.mjs';
import { Runtime } from '../runtimes/Runtime.mjs';
import { createRuntime } from '../runtimes/index.mjs';
import { startupRuntime } from '../server.mjs';

// What a runtime that drives an external session (one other clients also drive) relies on in
// Session, and how plugin conversations are kept beside the built-ins'.

const FIXTURE = fileURLToPath(new URL('./fixtures/echo-agent', import.meta.url));

/** A scripted runtime that follows the contract in runtimes/Runtime.mjs. */
class Scripted extends Runtime {
  static id = 'codex'; static displayName = 'Scripted';
  answers = []; submitted = []; state = {};
  get capabilities() { return { approvals: true, folderScope: false, modelRouting: false, cancel: true }; }
  async start(_cwd, { saved }) {
    this.saved = saved;
    if (this.beforeStart) await this.beforeStart();
    return { threadId: saved.threadId ?? 'scripted-thread', lastTurn: null };
  }
  async submit(text, { beforeSend }) { await beforeSend({}); this.submitted.push(text); return { turnId: `turn-${this.submitted.length}` }; }
  approve(id, decision) { this.answers.push([id, decision]); }
  async reset() { return { threadId: 'scripted-reset' }; }
  persistentState() { return { ...this.state }; }
}
async function until(read, predicate, what, timeout = 5000) {
  const deadline = Date.now() + timeout;
  for (;;) {
    const value = await read();
    if (predicate(value)) return value;
    if (Date.now() > deadline) throw new Error(`Timed out waiting for ${what}`);
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}

test('a turn another client starts while idle is mirrored without a request ID, and blocks a submit until it ends', async () => {
  const runtime = new Scripted();
  const session = new Session({ runtime, cwd: '/workspace' });
  await session.initialize();
  await session.submit('earlier', 'external-request-0001');
  runtime.emit('completed', { turnId: 'turn-1', output: 'Earlier answer.' });
  assert.equal(session.snapshot().requestId, 'external-request-0001');
  runtime.emit('started', { turnId: 'elsewhere-1' });
  let snapshot = session.snapshot();
  assert.equal(snapshot.status, 'running');
  assert.equal(snapshot.turnId, 'elsewhere-1');
  assert.equal(snapshot.requestId, null);
  assert.equal(snapshot.output, '', 'the last answer is replaced');
  await assert.rejects(session.submit('mine', 'external-request-0002'), { status: 409 });
  runtime.emit('output', { turnId: 'elsewhere-1', text: 'Hello from elsewhere.' });
  runtime.emit('completed', { turnId: 'elsewhere-1', output: 'Hello from elsewhere.' });
  snapshot = session.snapshot();
  assert.equal(snapshot.status, 'idle');
  assert.equal(snapshot.output, 'Hello from elsewhere.');
  assert.equal(snapshot.requestId, null);
  assert.deepEqual(runtime.submitted, ['earlier']);
});

test('an approval answered in another client is withdrawn from the snapshot', async () => {
  const runtime = new Scripted();
  const session = new Session({ runtime, cwd: '/workspace' });
  await session.initialize();
  await session.submit('go', 'external-request-0003');
  runtime.emit('started', { turnId: 'turn-1' });
  runtime.emit('approval', { id: 'native-1', turnId: 'turn-1', kind: 'command', reason: 'Run ls', command: 'ls', cwd: null });
  runtime.emit('approval', { id: 'native-2', turnId: 'turn-1', kind: 'command', reason: 'Run pwd', command: 'pwd', cwd: null });
  assert.equal(session.snapshot().approvals.length, 2);
  runtime.emit('approvalResolved', { id: 'native-1' });
  assert.equal(session.snapshot().status, 'approval');
  assert.deepEqual(session.snapshot().approvals.map(approval => approval.reason), ['Run pwd']);
  runtime.emit('approvalResolved', { id: 'native-2' });
  assert.equal(session.snapshot().status, 'running');
  assert.equal(session.snapshot().progress, 'Answered elsewhere');
  assert.deepEqual(session.snapshot().approvals, []);
  runtime.emit('approvalResolved', { id: 'unknown' });
  assert.deepEqual(runtime.answers, [], 'nothing is answered on the runtime for a withdrawn approval');
});

test('state a runtime persists before start() returns is saved at once and handed back on the next start', async () => {
  const writes = [];
  let release;
  const first = new Scripted();
  first.beforeStart = async () => {
    // An external session was just launched: save how to find it before waiting for it.
    first.state = { launch: 'launch-7' };
    first.emit('persist');
    await new Promise(resolve => { release = resolve; });
  };
  const session = new Session({ runtime: first, cwd: '/workspace', save: async value => writes.push(structuredClone(value)) });
  const starting = session.initialize();
  await until(() => writes.length, length => length > 0, 'the early save');
  assert.equal(writes.at(-1).launch, 'launch-7');
  assert.equal(writes.at(-1).runtime, 'codex');
  // The companion stops here; the next one starts from what was saved.
  release(); await starting;
  const again = new Scripted();
  await new Session({ runtime: again, cwd: '/workspace', saved: { ...writes[0], permissions: undefined } }).initialize();
  assert.equal(again.saved.launch, 'launch-7');
});

test('a runtime cannot overwrite the state file\'s own keys', async () => {
  const writes = [];
  const runtime = new Scripted();
  runtime.state = { permissions: { mode: 'fullAccess', approvedFolders: ['/'] }, cwd: '/', runtime: 'hermes', conversations: {}, requestIds: ['x'], receipt: { requestId: 'x' }, marker: 'kept' };
  const session = new Session({ runtime, cwd: '/workspace', save: async value => writes.push(structuredClone(value)) });
  await session.initialize();
  await session.submit('hello', 'external-request-0004');
  const saved = writes.at(-1);
  assert.deepEqual(saved.permissions, { mode: 'approvedFolders', approvedFolders: ['/workspace'] });
  assert.equal(saved.runtime, 'codex');
  assert.equal(saved.cwd, undefined);
  assert.deepEqual(saved.requestIds, ['external-request-0004']);
  assert.equal(saved.receipt.requestId, 'external-request-0004');
  assert.equal(saved.marker, 'kept');
});

async function pluginFolder(t) {
  const root = await realpath(await mkdtemp(path.join(tmpdir(), 'brainkit-external-')));
  t.after(() => rm(root, { recursive: true, force: true }));
  const directory = path.join(root, 'Runtimes', 'echo-agent');
  await mkdir(path.dirname(directory), { recursive: true, mode: 0o755 });
  await cp(FIXTURE, directory, { recursive: true });
  await chmod(path.dirname(directory), 0o755);
  await chmod(directory, 0o755);
  for (const file of ['runtime.json', 'adapter.mjs']) await chmod(path.join(directory, file), 0o644);
  return { 'echo-agent': { directory, executable: '/bin/echo' } };
}

test('switching plugin → built-in → plugin keeps each conversation under its runtime id', async t => {
  const plugins = await pluginFolder(t);
  const writes = [];
  const build = name => (name === 'echo-agent' ? createRuntime(name, { plugins }) : new Scripted());
  const session = new Session({ runtime: await build('echo-agent'), cwd: '/workspace', createRuntime: build, save: async value => writes.push(structuredClone(value)) });
  await session.initialize();
  assert.equal(session.snapshot().threadId, 'echo-thread-1');
  await session.reset();
  assert.equal(session.snapshot().threadId, 'echo-thread-2');
  await session.switchRuntime('codex');
  assert.equal(session.snapshot().runtime, 'codex');
  assert.deepEqual(writes.at(-1).conversations['echo-agent'], { threads: 2, threadId: 'echo-thread-2' });
  await session.switchRuntime('echo-agent');
  assert.equal(session.snapshot().runtime, 'echo-agent');
  assert.equal(session.snapshot().threadId, 'echo-thread-2', 'the plugin resumes its own conversation');
  assert.deepEqual(writes.at(-1).conversations.codex, { threadId: 'scripted-thread' });
  assert.equal(writes.at(-1).threads, 2);
});

test('a saved plugin the host no longer passes falls back to Codex and resumes when it is back', async t => {
  const plugins = await pluginFolder(t);
  const saved = { runtime: 'echo-agent', threadId: 'echo-thread-1', threads: 1, permissions: { mode: 'approvedFolders', approvedFolders: [path.dirname(plugins['echo-agent'].directory)] } };
  assert.equal(startupRuntime({}, saved, {}), 'codex');
  assert.equal(startupRuntime({}, saved, plugins), 'echo-agent');
  assert.equal(startupRuntime({ '--runtime': 'hermes' }, saved, plugins), 'hermes');
  assert.equal(startupRuntime({}, {}, plugins), 'codex');
  // Without the plugin: Codex runs, and the plugin's conversation is kept.
  const cwd = saved.permissions.approvedFolders[0];
  const writes = [];
  const build = name => (name === 'echo-agent' ? createRuntime(name, { plugins }) : new Scripted());
  const session = new Session({ runtime: new Scripted(), cwd, saved, createRuntime: build, save: async value => writes.push(structuredClone(value)) });
  await session.initialize();
  assert.equal(writes.at(-1).runtime, 'codex');
  assert.deepEqual(writes.at(-1).conversations['echo-agent'], { threadId: 'echo-thread-1', threads: 1 });
  await session.switchRuntime('echo-agent');
  assert.equal(session.snapshot().threadId, 'echo-thread-1');
});
