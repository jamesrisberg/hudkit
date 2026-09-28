import test from 'node:test';
import assert from 'node:assert/strict';
import { fileURLToPath } from 'node:url';
import { realpath } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { Session } from '../session.mjs';
import { CodexRuntime } from '../runtimes/codex.mjs';

const FAKE = fileURLToPath(new URL('./fixtures/fake-codex.mjs', import.meta.url));
async function until(session, predicate) {
  const deadline = Date.now() + 5000;
  while (!predicate(session.snapshot())) {
    if (Date.now() > deadline) throw new Error(`Timed out at ${JSON.stringify(session.snapshot())}`);
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  return session.snapshot();
}

test('the Codex adapter drives a stdio JSON-RPC app-server: routing, streaming, approval, interrupt', async t => {
  const runtime = new CodexRuntime({ executable: FAKE });
  t.after(() => runtime.close());
  const session = new Session({ runtime, cwd: await realpath(tmpdir()) });
  await session.initialize();
  assert.equal(session.snapshot().threadId, 'thread-A');
  assert.deepEqual(session.snapshot().routing, { mode: 'automatic', available: true, fastModel: 'gpt-5.6-luna', deepModel: 'gpt-6-astra' });

  await session.submit('What is the capital of France?', 'codex-stdio-000001');
  let done = await until(session, s => s.status === 'idle' && s.turnId === 'turn-1');
  assert.equal(done.output, 'Echo: What is the capital of France?');
  assert.equal(done.route.model, 'gpt-5.6-luna'); assert.equal(done.requestId, 'codex-stdio-000001');

  await session.submit('Debug this, it needs approval', 'codex-stdio-000002');
  const waiting = await until(session, s => s.status === 'approval');
  assert.equal(waiting.route.model, 'gpt-6-astra');
  assert.equal(waiting.output, 'Working on it');
  assert.deepEqual({ ...waiting.approvals[0], id: 'x' }, { id: 'x', kind: 'command', reason: 'Write outside the workspace?', command: 'touch /outside/file', cwd: '/workspace' });
  session.approve(waiting.approvals[0].id, 'accept');
  done = await until(session, s => s.status === 'idle' && s.turnId === 'turn-2');
  assert.equal(done.output, 'Ran it.');

  await session.submit('Please wait for me', 'codex-stdio-000003');
  await until(session, s => s.turnId === 'turn-3');
  await session.cancel();
  done = await until(session, s => s.status === 'interrupted');
  assert.equal(done.progress, 'Interrupted');
});
