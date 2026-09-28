import test from 'node:test';
import assert from 'node:assert/strict';
import { Session } from '../session.mjs';
import { Runtime } from '../runtimes/Runtime.mjs';
import { createRuntime } from '../runtimes/index.mjs';
import { parseArguments } from '../server.mjs';

// A scripted runtime that follows the contract in runtimes/Runtime.mjs.
function fakeRuntime(id, { failStart = false } = {}) {
  return new (class extends Runtime {
    static id = id; static displayName = id.toUpperCase();
    started = []; submitted = []; closed = false; answers = [];
    get capabilities() { return { approvals: true, folderScope: false, modelRouting: false, cancel: true }; }
    async start(cwd, { saved }) {
      if (failStart) throw new Error(`${id} is not running`);
      this.started.push(saved);
      return { threadId: saved.threadId ?? `${id}-thread-${this.started.length}`, lastTurn: null };
    }
    async submit(text, { beforeSend }) { await beforeSend({}); this.submitted.push(text); return { turnId: `${id}-turn-${this.submitted.length}` }; }
    approve(id, decision) { this.answers.push([id, decision]); }
    async reset() { return { threadId: `${id}-reset` }; }
    persistentState() { return { marker: id }; }
    close() { this.closed = true; }
  })();
}

test('switching runtime keeps permissions and request IDs, stashes and resumes each conversation', async () => {
  const writes = []; const built = {};
  const createRuntime = name => (built[name] = fakeRuntime(name));
  const session = new Session({ runtime: createRuntime('codex'), cwd: '/workspace', createRuntime, save: async value => writes.push(structuredClone(value)) });
  await session.initialize();
  await session.submit('hello', 'request-1');
  await assert.rejects(session.switchRuntime('hermes'), { status: 409 });
  built.codex.emit('completed', { turnId: 'codex-turn-1', output: 'Hi.' });
  const switched = await session.switchRuntime('hermes');
  assert.equal(built.codex.closed, true);
  assert.equal(switched.runtime, 'hermes');
  assert.equal(switched.threadId, 'hermes-thread-1');
  assert.equal(switched.status, 'idle'); assert.equal(switched.output, '');
  assert.deepEqual(switched.capabilities, { approvals: true, folderScope: false, modelRouting: false, cancel: true });
  const saved = writes.at(-1);
  assert.equal(saved.runtime, 'hermes'); assert.equal(saved.marker, 'hermes');
  assert.deepEqual(saved.conversations.codex, { marker: 'codex', threadId: 'codex-thread-1' });
  assert.ok(saved.requestIds.includes('request-1'));
  assert.equal((await session.submit('replayed', 'request-1')).runtime, 'hermes');
  assert.equal(built.hermes.submitted.length, 0);
  // Restart with the saved state and switch back: Codex resumes its own thread.
  const again = new Session({ runtime: createRuntime('hermes'), cwd: '/workspace', saved: { ...saved, permissions: undefined }, createRuntime, save: async value => writes.push(structuredClone(value)) });
  await again.initialize();
  assert.equal(built.hermes.started[0].threadId, 'hermes-thread-1');
  await again.switchRuntime('codex');
  assert.equal(built.codex.started[0].threadId, 'codex-thread-1');
  assert.equal(built.codex.started[0].marker, 'codex');
});

test('a legacy state file belongs to Codex; choosing another runtime at startup never reuses its thread or receipt', async () => {
  const hermes = fakeRuntime('hermes');
  const session = new Session({ runtime: hermes, cwd: '/workspace', saved: { threadId: 'codex-thread', lastRouteTier: 'deep', receipt: { requestId: 'r', previousTurnId: null, acceptedTurnId: null } } });
  await session.initialize();
  assert.equal(hermes.started[0].threadId, undefined);
  assert.equal(session.receipt, null);
  assert.deepEqual(session.conversations.codex, { threadId: 'codex-thread', lastRouteTier: 'deep' });
});

test('a runtime that cannot start reports failure, persists the choice, and can be switched away from', async () => {
  const writes = [];
  const createRuntime = name => fakeRuntime(name, { failStart: name === 'hermes' });
  const session = new Session({ runtime: createRuntime('codex'), cwd: '/workspace', createRuntime, save: async value => writes.push(value) });
  await session.initialize();
  await assert.rejects(session.switchRuntime('hermes'), { status: 503, message: /hermes is not running/ });
  assert.equal(session.snapshot().status, 'failed');
  assert.equal(session.snapshot().runtime, 'hermes');
  assert.equal(writes.at(-1).runtime, 'hermes');
  await assert.rejects(session.submit('hello', 'request-2'), { status: 503 });
  assert.equal((await session.switchRuntime('codex')).status, 'idle');
});

test('approvals from a runtime get opaque IDs and are declined when not expected', async () => {
  const runtime = fakeRuntime('claude');
  const session = new Session({ runtime, cwd: '/workspace' });
  await session.initialize();
  runtime.emit('approval', { id: 'native-early', turnId: 'x', kind: 'command', reason: 'Too early' });
  assert.deepEqual(runtime.answers, [['native-early', 'decline']]);
  await session.submit('go', 'request-3');
  runtime.emit('started', { turnId: 'claude-turn-1' });
  runtime.emit('approval', { id: 'native-1', turnId: 'claude-turn-1', kind: 'command', reason: 'Run ls', command: 'ls', cwd: null });
  const [approval] = session.snapshot().approvals;
  assert.notEqual(approval.id, 'native-1');
  assert.deepEqual(approval, { id: approval.id, kind: 'command', reason: 'Run ls', command: 'ls', cwd: null });
  session.approve(approval.id, 'accept');
  assert.deepEqual(runtime.answers.at(-1), ['native-1', 'accept']);
  runtime.emit('failed', { turnId: 'claude-turn-1', output: '', error: 'boom' });
  assert.equal(session.snapshot().status, 'failed'); assert.equal(session.snapshot().error, 'boom');
});

test('command line selects a known runtime once; unknown runtimes are rejected before any work', () => {
  assert.deepEqual(parseArguments(['--cwd', '/w', '--runtime', 'codex', '--runtime-url', 'http://127.0.0.1:8642']), { '--cwd': '/w', '--runtime': 'codex', '--runtime-url': 'http://127.0.0.1:8642' });
  assert.throws(() => parseArguments(['--cwd', '/w', '--runtime', 'gpt']), /--runtime must be one of/);
  assert.throws(() => parseArguments(['--cwd', '/w', '--cwd', '/x']), /Usage/);
  assert.throws(() => parseArguments(['--runtime-token', 'a', '--runtime-token-file', '/b']), /either/);
  assert.throws(() => createRuntime('gpt'), { status: 400 });
  assert.equal(createRuntime('codex').id, 'codex');
});

test('a runtime that fails to start keeps its saved conversation; a retry resumes it and keeps the receipt', async () => {
  let attempts = 0; const writes = [];
  const createRuntime = name => {
    const runtime = fakeRuntime(name, { failStart: name === 'hermes' && attempts++ === 0 });
    return runtime;
  };
  const receipt = { requestId: 'uncertain', previousTurnId: null, acceptedTurnId: null };
  const session = new Session({ runtime: createRuntime('hermes'), cwd: '/workspace', createRuntime, save: async value => writes.push(structuredClone(value)),
    saved: { runtime: 'hermes', threadId: 'hermes-saved', marker: 'saved', lastRunId: 'run_1', requestIds: ['uncertain'], receipt } });
  await assert.rejects(session.initialize(), /hermes is not running/);
  assert.equal(session.snapshot().threadId, 'hermes-saved');
  const snapshot = await session.switchRuntime('hermes'); // the second attempt succeeds
  assert.equal(snapshot.status, 'idle');
  assert.equal(snapshot.threadId, 'hermes-saved');
  assert.deepEqual(session.receipt, receipt);
  const failedWrites = writes.filter(value => value.threadId === null);
  assert.equal(failedWrites.length, 0);
});
