import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readdir, readFile, realpath, rm } from 'node:fs/promises';
import net from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Session } from '../session.mjs';
import { MclaudeRuntime, mclaudeFailure } from '../runtimes/mclaude.mjs';

const FAKE = fileURLToPath(new URL('./fixtures/fake-mclaude.mjs', import.meta.url));

// Unix socket paths are limited to 104 bytes, so the state directory stays short.
async function setup(t, { saved = {}, permissions, env = {} } = {}) {
  const directory = await realpath(await mkdtemp(path.join('/tmp', 'bk-mc-')));
  const workspace = path.join(directory, 'w');
  await import('node:fs/promises').then(fs => fs.mkdir(workspace));
  const state = path.join(directory, 's');
  const log = path.join(directory, 'calls.jsonl');
  const environment = { ...process.env, MCLAUDE_STATE_DIR: state, FAKE_MCLAUDE_LOG: log, CLAUDECODE: '1', CLAUDE_CODE_CHILD_SESSION: '1', ...env };
  const runtimes = [];
  const build = () => { const runtime = new MclaudeRuntime({ executable: FAKE, stateDirectory: state, env: environment, settleMs: 50, killTimeout: 2000 }); runtimes.push(runtime); return runtime; };
  const writes = [];
  const makeSession = (savedState = saved) => new Session({ runtime: build(), cwd: workspace, saved: { ...savedState, ...(permissions ? { permissions } : {}) }, save: async value => writes.push(structuredClone(value)) });
  t.after(async () => {
    for (const runtime of runtimes) runtime.close();
    // End every fake session this test started.
    for (const name of await readdir(state).catch(() => [])) {
      const match = /^cc-(\d+)\.meta\.json$/.exec(name);
      if (match) try { process.kill(Number(match[1]), 'SIGTERM'); } catch {}
    }
    await new Promise(resolve => setTimeout(resolve, 50));
    await rm(directory, { recursive: true, force: true });
  });
  const calls = async () => (await readFile(log, 'utf8').catch(() => '')).trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
  const metas = async () => {
    const out = [];
    for (const name of await readdir(state).catch(() => [])) if (name.endsWith('.meta.json')) out.push(JSON.parse(await readFile(path.join(state, name), 'utf8')));
    return out;
  };
  return { makeSession, writes, calls, metas, workspace, state };
}
async function waitFor(predicate, message = 'condition', timeout = 5000) {
  const deadline = Date.now() + timeout;
  while (!(await predicate())) {
    if (Date.now() > deadline) throw new Error(`Timed out waiting for ${message}`);
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}
/** A second client on the session's socket, the way MechaHUD's dashboard drives it. */
async function otherClient(t, sock) {
  const socket = net.connect(sock);
  await new Promise((resolve, reject) => { socket.once('connect', resolve); socket.once('error', reject); });
  t.after(() => socket.destroy());
  socket.on('data', () => {});
  return { send: frame => socket.write(JSON.stringify({ type: 'control', ...frame }) + '\n') };
}
const flag = (args, name) => args[args.indexOf(name) + 1];

test('starts a brainkit-tagged mclaude session and streams one main-conversation answer', async t => {
  const { makeSession, calls, metas, workspace, writes } = await setup(t);
  const session = makeSession();
  await session.initialize();
  const [call] = await calls();
  assert.ok(call.args.includes('--mc-detach'));
  assert.match(flag(call.args, '--mc-tag'), /^brainkit-[0-9a-f]{12}$/);
  assert.equal(flag(call.args, '--mc-name'), flag(call.args, '--mc-tag'));
  assert.equal(flag(call.args, '--mc-cwd'), workspace);
  assert.equal(flag(call.args, '--permission-mode'), 'acceptEdits');
  assert.match(flag(call.args, '--append-system-prompt'), /^You are a capable personal voice assistant/);
  assert.ok(!call.args.includes('--add-dir') && !call.args.includes('--resume'));
  // A companion started inside a Claude Code session must not launch a nested-looking one.
  assert.equal(call.claudecode, null); assert.equal(call.childSession, null);
  const [meta] = await metas();
  const snapshot = session.snapshot();
  assert.equal(snapshot.runtime, 'mclaude');
  assert.equal(snapshot.threadId, meta.sessionId);
  assert.equal(snapshot.sessionKey, `claude:${meta.sessionId}`);
  assert.deepEqual(snapshot.capabilities, { approvals: true, folderScope: true, modelRouting: false, cancel: true });
  assert.equal(writes.at(-1).tag, flag(call.args, '--mc-tag'));
  await session.submit('hello', 'mclaude-request-0001');
  await waitFor(() => session.snapshot().status === 'idle' && session.snapshot().output, 'the answer');
  const done = session.snapshot();
  // The session-title stream (another querySource) is never part of the answer.
  assert.equal(done.output, 'Hello there.');
  assert.equal(done.requestId, 'mclaude-request-0001');
  assert.equal(done.progress, 'Done');
});

test('permission prompts become one-time approvals answered through the select overlay', async t => {
  const { makeSession } = await setup(t);
  const session = makeSession();
  await session.initialize();
  await session.submit('approve this', 'mclaude-request-0010');
  await waitFor(() => session.snapshot().status === 'approval', 'the approval');
  const [approval] = session.snapshot().approvals;
  assert.deepEqual({ ...approval, id: 'x' }, { id: 'x', kind: 'command', reason: 'Delete the demo folder', command: 'rm -rf /tmp/demo', cwd: null });
  session.approve(approval.id, 'accept');
  await waitFor(() => session.snapshot().status === 'idle', 'the allowed turn');
  assert.equal(session.snapshot().output, 'Allowed rm -rf /tmp/demo');
  await session.submit('approve that', 'mclaude-request-0011');
  await waitFor(() => session.snapshot().status === 'approval', 'the second approval');
  session.approve(session.snapshot().approvals[0].id, 'decline');
  await waitFor(() => session.snapshot().status === 'idle', 'the denied turn');
  assert.equal(session.snapshot().output, 'Denied.');
});

test('a turn another client starts is mirrored, and an approval it answers clears', async t => {
  const { makeSession, metas } = await setup(t);
  const session = makeSession();
  await session.initialize();
  const [meta] = await metas();
  const dashboard = await otherClient(t, meta.sock);
  dashboard.send({ action: 'submit', text: 'hello from the dashboard' });
  await waitFor(() => session.snapshot().status === 'idle' && session.snapshot().output === 'Hello there.', 'the mirrored answer');
  assert.equal(session.snapshot().requestId, null);
  // While another client's turn runs, the voice cannot start one.
  dashboard.send({ action: 'submit', text: 'approve from the dashboard' });
  await waitFor(() => session.snapshot().status === 'approval', 'the mirrored approval');
  await assert.rejects(session.submit('hello', 'mclaude-request-0020'), { status: 409 });
  dashboard.send({ action: 'choose', index: 0 });
  await waitFor(() => session.snapshot().status === 'idle', 'the turn to finish after the dashboard answered');
  assert.deepEqual(session.snapshot().approvals, []);
  assert.equal(session.snapshot().output, 'Allowed rm -rf /tmp/demo');
});

test('cancel interrupts the session and waits for it to stop', async t => {
  const { makeSession } = await setup(t);
  const session = makeSession();
  await session.initialize();
  await session.submit('slow story', 'mclaude-request-0030');
  await waitFor(() => session.snapshot().output === 'Once upon', 'streamed text');
  await session.cancel();
  await waitFor(() => session.snapshot().status === 'interrupted', 'the interruption');
  assert.equal(session.snapshot().output, 'Once upon');
  await assert.rejects(session.cancel(), { status: 409 });
});

test('an API error that ends the turn without an answer is a failed turn', async t => {
  const { makeSession } = await setup(t);
  const session = makeSession();
  await session.initialize();
  await session.submit('fail please', 'mclaude-request-0040');
  await waitFor(() => session.snapshot().status === 'failed', 'the failure');
  assert.match(session.snapshot().error, /529 overloaded/);
});

test('a restarted companion reattaches to its live session; a gone session is replaced by a new one', async t => {
  const { makeSession, calls, metas, writes } = await setup(t);
  const first = makeSession();
  await first.initialize();
  const saved = writes.at(-1);
  first.runtime.close();
  const again = makeSession(saved);
  await again.initialize();
  assert.equal((await calls()).length, 1, 'no second launch');
  const [meta] = await metas();
  assert.equal(again.snapshot().sessionKey, `claude:${meta.sessionId}`);
  await again.submit('hello', 'mclaude-request-0050');
  await waitFor(() => again.snapshot().status === 'idle' && again.snapshot().output, 'the answer after reattaching');
  // The session ends (closed in its terminal): the runtime reports it, and the next start launches anew.
  process.kill(meta.pid, 'SIGTERM');
  await waitFor(() => again.snapshot().status === 'failed', 'the disconnect');
  assert.match(again.snapshot().error, /mclaude session ended/);
  const third = makeSession(writes.at(-1));
  await third.initialize();
  assert.equal((await calls()).length, 2);
  assert.notEqual(third.snapshot().sessionKey, `claude:${meta.sessionId}`);
});

test('changing permissions relaunches the session on the same conversation', async t => {
  const { makeSession, calls, metas, workspace } = await setup(t);
  const extra = await realpath(await mkdtemp(path.join(tmpdir(), 'bk-mc-extra-')));
  t.after(() => rm(extra, { recursive: true, force: true }));
  const session = makeSession();
  await session.initialize();
  await session.submit('hello', 'mclaude-request-0059');
  await waitFor(() => session.snapshot().status === 'idle' && session.snapshot().output, 'the first answer');
  const [before] = await metas();
  await session.setPermissions({ mode: 'fullAccess', approvedFolders: [workspace, extra] });
  const second = (await calls())[1];
  assert.equal(flag(second.args, '--permission-mode'), 'bypassPermissions');
  assert.equal(flag(second.args, '--add-dir'), extra);
  assert.equal(flag(second.args, '--resume'), before.sessionId);
  await waitFor(async () => (await metas()).length === 1 && (await metas())[0].pid !== before.pid, 'the old session to end');
  await session.submit('hello', 'mclaude-request-0060');
  await waitFor(() => session.snapshot().status === 'idle' && session.snapshot().output, 'the answer after relaunch');
});

test('new conversation clears the session and follows its new id', async t => {
  const { makeSession } = await setup(t);
  const session = makeSession();
  await session.initialize();
  const before = session.snapshot().sessionKey;
  const reset = await session.reset();
  assert.notEqual(reset.sessionKey, before);
  assert.equal(reset.sessionKey, `claude:${reset.threadId}`);
});

test('the folder-trust prompt of the chosen workspace is accepted at start', async t => {
  const { makeSession } = await setup(t, { env: { FAKE_MCLAUDE_GATED: '1' } });
  const session = makeSession();
  await session.initialize();
  await session.submit('hello', 'mclaude-request-0070');
  await waitFor(() => session.snapshot().status === 'idle' && session.snapshot().output, 'the answer');
});

test('launch failures carry mechaclaude\'s reason in words a user can act on', async t => {
  assert.equal(mclaudeFailure('mclaude: --mc-detach requires tmux'), 'mclaude sessions need tmux: brew install tmux');
  assert.equal(mclaudeFailure('mclaude: starting directory does not exist: /x'), 'mclaude could not start a session: starting directory does not exist: /x');
  const { makeSession } = await setup(t, { env: { FAKE_MCLAUDE_FAIL: '--mc-detach requires tmux' } });
  await assert.rejects(makeSession().initialize(), { message: 'mclaude sessions need tmux: brew install tmux' });
  const missing = new MclaudeRuntime({ executable: '/nonexistent/mclaude' });
  await assert.rejects(missing.start('/w', { saved: {}, permissions: { mode: 'approvedFolders', approvedFolders: ['/w'] }, instructions: '' }), /mclaude is not installed/);
});
