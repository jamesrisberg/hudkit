import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdtemp, stat, readFile, chmod, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createServer, loadToken, saveState } from '../server.mjs';

const token = 'a'.repeat(64);
async function fixture(t) {
  const calls = [];
  const session = { snapshot: () => ({ status: 'idle' }), submit: async (...args) => { calls.push(args); return { status: 'running' }; }, setPermissions: async value => { calls.push(value); return { permissions: value }; }, approve: () => ({}), cancel: async () => ({}), switchRuntime: async name => { calls.push({ runtime: name }); return { runtime: name }; } };
  const server = createServer({ session, token });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const port = server.address().port;
  function request({ route = '/v1/session', method = 'GET', headers = {}, value } = {}) {
    return new Promise((resolve, reject) => {
      const req = http.request({ hostname: '127.0.0.1', port, path: route, method, headers: { Authorization: `Bearer ${token}`, ...headers } }, res => {
        let data = ''; res.on('data', chunk => { data += chunk; }); res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(data) }));
      });
      req.on('error', reject); req.end(value);
    });
  }
  return { request, calls };
}
test('native bearer client only; rejects DNS rebinding, origins, unauthorized requests', async t => {
  const { request, calls } = await fixture(t);
  assert.equal((await request()).status, 200);
  assert.equal((await request({ headers: { Authorization: 'Bearer wrong' } })).status, 401);
  assert.equal((await request({ headers: { Host: 'evil.example' } })).status, 403);
  assert.equal((await request({ headers: { Origin: 'http://evil.example' } })).status, 403);
  assert.equal((await request({ headers: { Origin: 'null' } })).status, 403);
  assert.equal((await request({ headers: { 'Sec-Fetch-Site': 'same-origin' } })).status, 403);
  assert.equal(calls.length, 0);
});
test('request schema forbids network supplied workspace, policies and broad approval', async t => {
  const { request, calls } = await fixture(t);
  const post = value => request({ route: '/v1/turn', method: 'POST', headers: { 'Content-Type': 'application/json' }, value: JSON.stringify(value) });
  assert.equal((await post({ text: 'Hello', requestId: '1234567890123456', cwd: '/' })).status, 400);
  assert.equal((await post({ text: 'Hello', requestId: '1234567890123456', sandbox: 'danger-full-access' })).status, 400);
  assert.equal((await post({ text: 'x'.repeat(40000), requestId: '1234567890123456' })).status, 413);
  assert.equal((await post({ text: 'Hello', requestId: '1234567890123456' })).status, 200);
  assert.equal((await request({ route: '/v1/approval', method: 'POST', headers: { 'Content-Type': 'application/json' }, value: JSON.stringify({ id: 'approval', decision: 'acceptForSession' }) })).status, 400);
  assert.equal(calls.length, 1);
});
test('token persists privately and rejects symlinks and permissive credentials', async t => {
  const directory = await mkdtemp(path.join(tmpdir(), 'brainkit-token-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const first = await loadToken(directory);
  assert.match(first, /^[a-f0-9]{64}$/);
  assert.equal(await loadToken(directory), first);
  assert.equal((await stat(path.join(directory, 'token'))).mode & 0o777, 0o600);
  await chmod(path.join(directory, 'token'), 0o644);
  await assert.rejects(loadToken(directory), /private/);
  await rm(path.join(directory, 'token'));
  await writeFile(path.join(directory, 'other'), token, { mode: 0o600 });
  await symlink(path.join(directory, 'other'), path.join(directory, 'token'));
  await assert.rejects(loadToken(directory));
  await saveState(directory, { threadId: 'one' });
  assert.equal((await stat(path.join(directory, 'session.json'))).mode & 0o777, 0o600);
  assert.deepEqual(JSON.parse(await readFile(path.join(directory, 'session.json'))), { threadId: 'one' });
});

test('permissions endpoint is authenticated, exact, and separate from model text submissions', async t => {
  const { request, calls } = await fixture(t);
  const post = (value, headers = {}) => request({ route: '/v1/permissions', method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, value: JSON.stringify(value) });
  const policy = { mode: 'fullAccess', approvedFolders: ['/workspace'] };
  assert.equal((await post(policy, { Authorization: 'Bearer wrong' })).status, 401);
  assert.equal((await post(policy, { Origin: 'http://localhost' })).status, 403);
  assert.equal((await post({ ...policy, approvalPolicy: 'never' })).status, 400);
  const accepted = await post(policy);
  assert.equal(accepted.status, 200);
  assert.deepEqual(accepted.body.permissions, policy);
  assert.deepEqual(calls, [policy]);
});

test('runtime endpoint accepts only a known runtime name, authenticated', async t => {
  const { request, calls } = await fixture(t);
  const post = (value, headers = {}) => request({ route: '/v1/runtime', method: 'POST', headers: { 'Content-Type': 'application/json', ...headers }, value: JSON.stringify(value) });
  assert.equal((await post({ runtime: 'codex' }, { Authorization: 'Bearer wrong' })).status, 401);
  assert.equal((await post({ runtime: 'gpt' })).status, 400);
  assert.equal((await post({ runtime: 'codex', url: 'http://evil.example' })).status, 400);
  const accepted = await post({ runtime: 'codex' });
  assert.equal(accepted.status, 200);
  assert.deepEqual(accepted.body, { runtime: 'codex' });
  assert.deepEqual(calls, [{ runtime: 'codex' }]);
});
