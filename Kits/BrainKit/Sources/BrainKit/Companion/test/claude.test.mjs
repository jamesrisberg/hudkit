import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, realpath, rm } from 'node:fs/promises';
import net from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Session } from '../session.mjs';
import { ClaudeRuntime, PERMISSION_TOOL, describe } from '../runtimes/claude.mjs';

const FAKE = fileURLToPath(new URL('./fixtures/fake-claude.mjs', import.meta.url));

async function setup(t, { saved, permissions } = {}) {
  const directory = await realpath(await mkdtemp(path.join(tmpdir(), 'brainkit-claude-test-')));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const log = path.join(directory, 'calls.jsonl');
  const runtime = new ClaudeRuntime({ executable: FAKE, killGrace: 500, env: { ...process.env, FAKE_CLAUDE_LOG: log, CLAUDECODE: '1' } });
  const writes = [];
  const session = new Session({ runtime, cwd: directory, saved: { ...saved, ...(permissions ? { permissions } : {}) }, save: async value => writes.push(structuredClone(value)) });
  t.after(() => runtime.close());
  await session.initialize();
  const calls = async () => (await readFile(log, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
  return { runtime, session, writes, calls, directory };
}
async function settle(session) {
  const deadline = Date.now() + 5000;
  while (['running'].includes(session.snapshot().status) && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10));
  return session.snapshot();
}
const flag = (args, name) => args[args.indexOf(name) + 1];

test('a turn streams main-conversation text, completes, and the next turn resumes the session', async t => {
  const { session, writes, calls, directory } = await setup(t);
  const threadId = session.snapshot().threadId;
  assert.match(threadId, /^[0-9a-f-]{36}$/);
  await session.submit('hello', 'claude-request-00001');
  const done = await settle(session);
  assert.equal(done.status, 'idle'); assert.equal(done.output, 'Hello there.'); assert.equal(done.requestId, 'claude-request-00001');
  assert.ok(done.timing.firstResponseMs >= 0);
  assert.equal(writes.at(-1).sessionStarted, true);
  await session.submit('hello again', 'claude-request-00002');
  await settle(session);
  const [first, second] = await calls();
  assert.equal(flag(first.args, '--session-id'), threadId); assert.ok(!first.args.includes('--resume'));
  assert.equal(flag(second.args, '--resume'), threadId); assert.ok(!second.args.includes('--session-id'));
  for (const call of [first, second]) {
    assert.deepEqual(call.args.slice(0, 7), ['-p', '--input-format', 'stream-json', '--output-format', 'stream-json', '--verbose', '--include-partial-messages']);
    assert.equal(flag(call.args, '--permission-mode'), 'acceptEdits');
    assert.equal(flag(call.args, '--permission-prompt-tool'), PERMISSION_TOOL);
    assert.match(flag(call.args, '--append-system-prompt'), /^You are a capable personal voice assistant/);
    assert.ok(!call.args.includes('--add-dir'));
    // The bridge token is passed in the environment only, and nesting markers are removed.
    assert.equal(call.hasToken, true); assert.equal(call.claudecode, null);
    assert.ok(!JSON.stringify(call.args).includes(session.runtime.bridgeToken));
  }
  assert.equal(directory, session.cwd);
  await session.reset();
  await session.submit('hello', 'claude-request-00003');
  await settle(session);
  const third = (await calls())[2];
  assert.notEqual(flag(third.args, '--session-id'), threadId);
});

test('permission prompts travel through the MCP bridge as one-time approvals', async t => {
  const { session } = await setup(t);
  await session.submit('approve this', 'claude-request-00010');
  const deadline = Date.now() + 5000;
  while (session.snapshot().status !== 'approval' && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10));
  const [approval] = session.snapshot().approvals;
  assert.deepEqual({ ...approval, id: 'x' }, { id: 'x', kind: 'command', reason: 'Delete the demo folder', command: 'rm -rf /tmp/demo', cwd: null });
  assert.equal(session.snapshot().progress, 'Waiting for your approval');
  session.approve(approval.id, 'accept');
  const done = await settle(session);
  assert.equal(done.output, 'Allowed rm -rf /tmp/demo');
  await session.submit('approve that', 'claude-request-00011');
  while (session.snapshot().status !== 'approval') await new Promise(resolve => setTimeout(resolve, 10));
  session.approve(session.snapshot().approvals[0].id, 'decline');
  assert.match((await settle(session)).output, /^Denied: The user denied this action/);
});

test('cancel interrupts with SIGINT and waits for the process to confirm', async t => {
  const { session } = await setup(t);
  await session.submit('slow story', 'claude-request-00020');
  while (session.snapshot().output !== 'Once upon') await new Promise(resolve => setTimeout(resolve, 10));
  await session.cancel();
  const done = await settle(session);
  assert.equal(done.status, 'interrupted'); assert.equal(done.output, 'Once upon');
  await assert.rejects(session.cancel(), { status: 409 });
});

test('a crash without a result is a failed turn with the CLI diagnostics', async t => {
  const { session } = await setup(t);
  await session.submit('crash now', 'claude-request-00030');
  const done = await settle(session);
  assert.equal(done.status, 'failed'); assert.match(done.error, /fatal: something broke/);
});

test('full access maps to bypassPermissions; extra approved folders become --add-dir', async t => {
  const extra = await realpath(await mkdtemp(path.join(tmpdir(), 'brainkit-claude-extra-')));
  t.after(() => rm(extra, { recursive: true, force: true }));
  const { session, calls, directory } = await setup(t);
  await session.setPermissions({ mode: 'approvedFolders', approvedFolders: [directory, extra] });
  await session.submit('hello', 'claude-request-00040'); await settle(session);
  await session.setPermissions({ mode: 'fullAccess', approvedFolders: [directory] });
  await session.submit('hello', 'claude-request-00041'); await settle(session);
  const [scoped, full] = await calls();
  assert.equal(flag(scoped.args, '--permission-mode'), 'acceptEdits'); assert.equal(flag(scoped.args, '--add-dir'), extra);
  assert.equal(flag(full.args, '--permission-mode'), 'bypassPermissions'); assert.ok(!full.args.includes('--add-dir'));
});

test('the approval socket refuses requests without the token or outside a turn', async t => {
  const { runtime } = await setup(t);
  const ask = payload => new Promise(resolve => {
    const socket = net.connect(runtime.socketPath, () => socket.write(JSON.stringify(payload) + '\n'));
    let data = ''; socket.setEncoding('utf8');
    socket.on('data', chunk => { data += chunk; }); socket.on('close', () => resolve(data)); socket.on('error', () => resolve('error'));
  });
  assert.equal(await ask({ token: 'wrong', tool_name: 'Bash', input: {} }), '');
  assert.match(await ask({ token: runtime.bridgeToken, tool_name: 'Bash', input: {} }), /"behavior":"deny"/);
  assert.deepEqual(describe('Write', { file_path: '/a/b.txt' }), { kind: 'tool', reason: 'Write /a/b.txt', command: null, cwd: null });
  assert.equal(describe('WebFetch', { url: 'https://x' }).command, '{"url":"https://x"}');
});

test('a missing CLI fails at start with an actionable message', async () => {
  await assert.rejects(new ClaudeRuntime({ executable: '/nonexistent/claude' }).start('/w', { permissions: { mode: 'approvedFolders', approvedFolders: ['/w'] }, instructions: '' }), /Claude Code CLI is not available.*not found/);
});
