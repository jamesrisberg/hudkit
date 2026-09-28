import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const server = fileURLToPath(new URL('../server.mjs', import.meta.url));

// The app keeps the companion's stdin open; closing it (app quit or crash) must end the companion.
test('BRAINKIT_PARENT_PIPE=1 exits when stdin closes', async t => {
  const workspace = await mkdtemp(path.join(tmpdir(), 'brainkit-ws-'));
  const state = await mkdtemp(path.join(tmpdir(), 'brainkit-state-'));
  t.after(() => Promise.all([rm(workspace, { recursive: true, force: true }), rm(state, { recursive: true, force: true })]));
  const port = String(20000 + Math.floor(Math.random() * 20000));
  // A codex that cannot start: the companion stays up and reports the runtime as failed.
  const child = spawn(process.execPath, [server, '--cwd', workspace, '--state-dir', state, '--port', port, '--runtime', 'codex', '--codex', '/usr/bin/false'], {
    env: { ...process.env, BRAINKIT_PARENT_PIPE: '1' }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  t.after(() => child.kill('SIGKILL'));
  let output = '';
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`no ready line: ${output}`)), 15000);
    const onData = chunk => { output += chunk; if (output.includes('ready at')) { clearTimeout(timer); resolve(); } };
    child.stdout.on('data', onData); child.stderr.on('data', onData);
    child.on('exit', code => { clearTimeout(timer); reject(new Error(`exited early ${code}: ${output}`)); });
  });
  child.removeAllListeners('exit');
  const exited = new Promise(resolve => child.on('exit', code => resolve(code)));
  child.stdin.end();
  let timer;
  const code = await Promise.race([exited, new Promise(resolve => { timer = setTimeout(() => resolve('timeout'), 8000); })]);
  clearTimeout(timer);
  assert.notEqual(code, 'timeout', 'companion kept running after its parent pipe closed');
});

test('SIGTERM still stops a companion that watches its parent pipe', async t => {
  const workspace = await mkdtemp(path.join(tmpdir(), 'brainkit-ws-'));
  const state = await mkdtemp(path.join(tmpdir(), 'brainkit-state-'));
  t.after(() => Promise.all([rm(workspace, { recursive: true, force: true }), rm(state, { recursive: true, force: true })]));
  const port = String(20000 + Math.floor(Math.random() * 20000));
  const child = spawn(process.execPath, [server, '--cwd', workspace, '--state-dir', state, '--port', port, '--runtime', 'codex', '--codex', '/usr/bin/false'], {
    env: { ...process.env, BRAINKIT_PARENT_PIPE: '1' }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  t.after(() => child.kill('SIGKILL'));
  let output = '';
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`no ready line: ${output}`)), 15000);
    const onData = chunk => { output += chunk; if (output.includes('ready at')) { clearTimeout(timer); resolve(); } };
    child.stdout.on('data', onData); child.stderr.on('data', onData);
  });
  const exited = new Promise(resolve => child.on('exit', code => resolve(code)));
  const started = Date.now();
  child.kill('SIGTERM');
  let timer;
  const code = await Promise.race([exited, new Promise(resolve => { timer = setTimeout(() => resolve('timeout'), 4000); })]);
  clearTimeout(timer);
  assert.notEqual(code, 'timeout', 'SIGTERM did not stop the companion');
  assert.ok(Date.now() - started < 4000);
});
