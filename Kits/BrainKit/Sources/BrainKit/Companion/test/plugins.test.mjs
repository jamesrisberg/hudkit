import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import http from 'node:http';
import { chmod, cp, mkdir, mkdtemp, readFile, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import net from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Session } from '../session.mjs';
import { Runtime, bounded } from '../runtimes/Runtime.mjs';
import { describe } from '../runtimes/claude.mjs';
import { allowedToolPatterns, claudeMcpServers } from '../tool-servers.mjs';
import { createRuntime, RUNTIME_IDS } from '../runtimes/index.mjs';
import { inspectPlugin, kit, pluginOptions } from '../runtimes/plugins.mjs';
import { parseArguments } from '../server.mjs';

const FIXTURE = fileURLToPath(new URL('./fixtures/echo-agent', import.meta.url));
const SERVER = fileURLToPath(new URL('../server.mjs', import.meta.url));
const TOOLS = { name: 'machud', command: '/bin/true', arguments: [], environment: {}, requireApproval: false };

/** A private Runtimes directory holding a copy of the fixture plugin (git does not keep modes). */
async function runtimesDirectory(t, name = 'echo-agent') {
  const root = await realpath(await mkdtemp(path.join(tmpdir(), 'brainkit-plugins-')));
  t.after(() => rm(root, { recursive: true, force: true }));
  const directory = path.join(root, 'Runtimes', name);
  await mkdir(path.dirname(directory), { recursive: true });
  await cp(FIXTURE, directory, { recursive: true });
  await chmod(directory, 0o755);
  for (const file of ['runtime.json', 'adapter.mjs']) await chmod(path.join(directory, file), 0o644);
  return { root, directory };
}
async function rewrite(directory, change) {
  const file = path.join(directory, 'runtime.json');
  await writeFile(file, JSON.stringify(change(JSON.parse(await readFile(file, 'utf8')))));
}
async function until(read, predicate, what, timeout = 5000) {
  const deadline = Date.now() + timeout;
  for (;;) {
    const value = await read();
    if (predicate(value)) return value;
    if (Date.now() > deadline) throw new Error(`Timed out waiting for ${what}`);
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}

test('the kit is frozen and carries exactly the companion helpers an adapter builds on', () => {
  assert.deepEqual(Object.keys(kit).sort(), ['Runtime', 'apiVersion', 'bounded', 'claude', 'toolServers']);
  assert.equal(kit.apiVersion, 1);
  assert.equal(kit.Runtime, Runtime);
  assert.equal(kit.bounded, bounded);
  assert.deepEqual(Object.keys(kit.claude), ['describe']);
  assert.equal(kit.claude.describe, describe);
  assert.deepEqual(Object.keys(kit.toolServers).sort(), ['allowedToolPatterns', 'claudeMcpServers']);
  assert.equal(kit.toolServers.allowedToolPatterns, allowedToolPatterns);
  assert.equal(kit.toolServers.claudeMcpServers, claudeMcpServers);
  for (const value of [kit, kit.claude, kit.toolServers]) assert.ok(Object.isFrozen(value));
});

test('a trusted plugin is read from its runtime.json; unknown keys are ignored', async t => {
  const { directory } = await runtimesDirectory(t);
  const plugin = await inspectPlugin('echo-agent', directory, { reserved: RUNTIME_IDS });
  assert.equal(plugin.directory, directory);
  assert.match(plugin.version, /^[\d.]+-\d+$/);
  assert.equal(plugin.adapter, path.join(directory, 'adapter.mjs'));
  assert.deepEqual(plugin.manifest, {
    schema: 1, id: 'echo-agent', title: 'Echo Agent', version: '1.0.0', adapter: 'adapter.mjs', executable: 'echo-agent',
    searchPaths: ['~/echo-agent/bin'], installCommand: 'echo install echo-agent', loginCommand: 'echo-agent login',
    summary: 'A runtime plugin for the tests.', docsURL: 'https://example.com/echo-agent',
  });
});

test('a plugin is refused unless its folder and files are private to this user and the adapter stays inside', async t => {
  const refused = async (directory, pattern, id = path.basename(directory)) =>
    assert.rejects(inspectPlugin(id, directory, { reserved: RUNTIME_IDS }), error => error.refusal === true && pattern.test(error.message));
  const { root, directory } = await runtimesDirectory(t);
  await chmod(directory, 0o775);
  await refused(directory, /echo-agent.*writable by other users/);
  await chmod(directory, 0o755);
  await chmod(path.join(directory, 'runtime.json'), 0o666);
  await refused(directory, /runtime\.json is writable by other users/);
  await chmod(path.join(directory, 'runtime.json'), 0o644);
  await chmod(path.join(directory, 'adapter.mjs'), 0o664);
  await refused(directory, /adapter "adapter\.mjs" is writable by other users/);
  await chmod(path.join(directory, 'adapter.mjs'), 0o644);
  // An adapter path, or a link, that leaves the plugin folder.
  await writeFile(path.join(root, 'Runtimes', 'outside.mjs'), 'export default () => null;', { mode: 0o644 });
  await rewrite(directory, value => ({ ...value, adapter: '../outside.mjs' }));
  await refused(directory, /adapter "\.\.\/outside\.mjs" is outside the plugin folder/);
  await rewrite(directory, value => ({ ...value, adapter: path.join(root, 'Runtimes', 'outside.mjs') }));
  await refused(directory, /outside the plugin folder/);
  await symlink(path.join(root, 'Runtimes', 'outside.mjs'), path.join(directory, 'linked.mjs'));
  await rewrite(directory, value => ({ ...value, adapter: 'linked.mjs' }));
  await refused(directory, /adapter "linked\.mjs" is a symbolic link/);
  const elsewhere = path.join(root, 'elsewhere');
  await mkdir(elsewhere);
  await writeFile(path.join(elsewhere, 'adapter.mjs'), 'export default () => null;', { mode: 0o644 });
  await symlink(elsewhere, path.join(directory, 'lib'));
  await rewrite(directory, value => ({ ...value, adapter: 'lib/adapter.mjs' }));
  await refused(directory, /adapter "lib\/adapter\.mjs" is outside the plugin folder/);
  await rewrite(directory, value => ({ ...value, adapter: 'missing.mjs' }));
  await refused(directory, /adapter "missing\.mjs" is missing/);
  // The descriptor itself.
  await rewrite(directory, value => ({ ...value, adapter: 'adapter.mjs', id: 'other-agent' }));
  await refused(directory, /id "other-agent" does not match its folder "echo-agent"/);
  await rewrite(directory, value => ({ ...value, id: 'echo-agent', schema: 2 }));
  await refused(directory, /schema 2.*schema 1/);
  await rewrite(directory, ({ title: _title, ...value }) => ({ ...value, schema: 1 }));
  await refused(directory, /"title" must be a non-empty string/);
  await refused(directory, /"requires" must be a list of strings/);
  await rewrite(directory, value => ({ ...value, requires: [], docsURL: 'file:///etc' }));
  await refused(directory, /"docsURL" must be an http or https URL/);
  await writeFile(path.join(directory, 'runtime.json'), '{ not json');
  await refused(directory, /runtime\.json is not valid JSON/);
  await rm(path.join(directory, 'runtime.json'));
  await refused(directory, /runtime\.json is missing/);
  // A linked runtime.json, and a plugin folder that is itself a link.
  await writeFile(path.join(elsewhere, 'runtime.json'), await readFile(path.join(FIXTURE, 'runtime.json')), { mode: 0o644 });
  await symlink(path.join(elsewhere, 'runtime.json'), path.join(directory, 'runtime.json'));
  await refused(directory, /^runtime\.json is a symbolic link$/);
  const linked = await runtimesDirectory(t);
  await symlink(linked.directory, path.join(root, 'Runtimes', 'linked-agent'));
  await refused(path.join(root, 'Runtimes', 'linked-agent'), /linked-agent is a symbolic link/);
  // Ids: the pattern, and never a built-in.
  const builtIn = await runtimesDirectory(t, 'codex');
  await rewrite(builtIn.directory, value => ({ ...value, id: 'codex' }));
  await refused(builtIn.directory, /codex is a built-in runtime/);
  await refused(directory, /"Echo" is not a valid runtime id/, 'Echo');
});

test('a plugin runtime starts, answers, cancels and resets through the session', async t => {
  const { directory } = await runtimesDirectory(t);
  const plugins = { 'echo-agent': { directory, executable: '/opt/echo/bin/echo-agent' } };
  const runtime = await createRuntime('echo-agent', { plugins, toolServers: [TOOLS] });
  assert.ok(runtime instanceof Runtime);
  const writes = [];
  const session = new Session({ runtime, cwd: directory, toolServers: [TOOLS], save: async value => writes.push(structuredClone(value)) });
  await session.initialize();
  assert.equal(session.snapshot().runtime, 'echo-agent');
  assert.equal(session.snapshot().threadId, 'echo-thread-1');
  assert.equal(session.snapshot().sessionKey, 'echo:0', 'options is reserved and empty');
  assert.deepEqual(session.snapshot().toolServers, { names: ['machud'], active: true, note: null });
  await session.submit('hello', 'plugin-request-0001');
  const done = await until(() => session.snapshot(), s => s.status === 'idle' && s.output, 'the answer');
  assert.equal(done.output, 'echo-agent: hello [mcp__machud__*]');
  assert.equal(done.requestId, 'plugin-request-0001');
  await session.submit('wait', 'plugin-request-0002');
  assert.equal(session.snapshot().status, 'running');
  assert.equal(session.snapshot().progress, 'Waiting to be cancelled');
  await session.cancel();
  assert.equal((await until(() => session.snapshot(), s => s.status !== 'running', 'the cancel')).status, 'interrupted');
  assert.equal((await session.reset()).threadId, 'echo-thread-2');
  assert.equal(writes.at(-1).runtime, 'echo-agent');
  assert.equal(writes.at(-1).threads, 2);
});

test('a refused or broken plugin is still offered but cannot start, and says why', async t => {
  const { root, directory } = await runtimesDirectory(t);
  const plugins = { 'echo-agent': { directory, executable: '/bin/echo' } };
  await chmod(directory, 0o777);
  const refused = await createRuntime('echo-agent', { plugins });
  assert.equal(refused.id, 'echo-agent');
  const session = new Session({ runtime: refused, cwd: directory });
  await assert.rejects(session.initialize(), /echo-agent cannot run: .*writable by other users/);
  await chmod(directory, 0o755);
  // An adapter whose runtime claims another id.
  await writeFile(path.join(directory, 'adapter.mjs'), `export default (kit) => new (class extends kit.Runtime { static id = 'codex'; })();`);
  await assert.rejects((await createRuntime('echo-agent', { plugins })).start(root, {}), /adapter made a runtime with id "codex", not "echo-agent"/);
  await writeFile(path.join(directory, 'adapter.mjs'), `export default () => ({ id: 'echo-agent' });`);
  await assert.rejects((await createRuntime('echo-agent', { plugins })).start(root, {}), /adapter must return a kit\.Runtime/);
  await writeFile(path.join(directory, 'second.mjs'), `export const create = () => null;`, { mode: 0o644 });
  await rewrite(directory, value => ({ ...value, adapter: 'second.mjs' }));
  await assert.rejects((await createRuntime('echo-agent', { plugins })).start(root, {}), /must default-export a factory function/);
});

test('plugins come from the command line: --runtime-plugin and --runtime-executable, and --runtime accepts their ids', async () => {
  const args = ['--cwd', '/w', '--runtime-plugin', 'echo-agent=/p/echo-agent', '--runtime-plugin', 'other=/p/other',
    '--runtime-executable', 'echo-agent=/bin/echo', '--runtime', 'echo-agent'];
  const options = parseArguments(args);
  assert.deepEqual(pluginOptions(options), { 'echo-agent': { directory: '/p/echo-agent', executable: '/bin/echo' }, other: { directory: '/p/other', executable: null } });
  assert.equal(options['--runtime'], 'echo-agent');
  assert.deepEqual(parseArguments(['--cwd', '/w']), { '--cwd': '/w' });
  assert.throws(() => parseArguments(['--cwd', '/w', '--runtime', 'echo-agent']), { message: `--runtime must be one of: ${RUNTIME_IDS.join(', ')}` });
  assert.throws(() => parseArguments(['--cwd', '/w', '--runtime-plugin', 'other=/p/other', '--runtime', 'gpt']), { message: `--runtime must be one of: ${[...RUNTIME_IDS, 'other'].join(', ')}` });
  assert.throws(() => parseArguments(['--runtime-plugin', 'Echo=/p/Echo']), /--runtime-plugin: "Echo" is not a valid runtime id/);
  assert.throws(() => parseArguments(['--runtime-plugin', 'codex=/p/codex']), /--runtime-plugin: codex is a built-in runtime/);
  assert.throws(() => parseArguments(['--runtime-plugin', 'echo-agent=relative/echo-agent']), /--runtime-plugin: .*absolute/);
  assert.throws(() => parseArguments(['--runtime-plugin', 'echo-agent=/a', '--runtime-plugin', 'echo-agent=/b']), /--runtime-plugin: echo-agent is given twice/);
  assert.throws(() => parseArguments(['--runtime-executable', 'echo-agent=/bin/echo']), /--runtime-executable: echo-agent is not a --runtime-plugin/);
  await assert.rejects(createRuntime('gpt', { plugins: { other: { directory: '/p/other', executable: null } } }),
    { status: 400, message: `Unknown runtime "gpt". Choose one of: ${[...RUNTIME_IDS, 'other'].join(', ')}` });
});

async function freePort() {
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  await new Promise(resolve => server.close(resolve));
  return port;
}

test('the companion runs a plugin given on its command line', async t => {
  const { root, directory } = await runtimesDirectory(t);
  const state = path.join(root, 'state');
  const port = await freePort();
  const child = spawn(process.execPath, [SERVER, '--cwd', root, '--state-dir', state, '--port', String(port),
    '--runtime-plugin', `echo-agent=${directory}`, '--runtime-executable', 'echo-agent=/bin/echo', '--runtime', 'echo-agent'],
  { stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(() => child.kill('SIGTERM'));
  let output = '';
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { output += chunk; });
  await until(() => output, text => text.includes('Brain companion ready at'), 'the companion');
  assert.match(output, /Runtime: echo-agent/);
  const token = (await readFile(path.join(state, 'token'), 'utf8')).trim();
  const call = (method, route, value) => new Promise((resolve, reject) => {
    const request = http.request({ host: '127.0.0.1', port, path: route, method, headers: { Authorization: `Bearer ${token}`, ...(value ? { 'Content-Type': 'application/json' } : {}) } }, response => {
      let data = ''; response.on('data', chunk => { data += chunk; }); response.on('end', () => resolve({ status: response.statusCode, body: JSON.parse(data) }));
    });
    request.on('error', reject); request.end(value ? JSON.stringify(value) : undefined);
  });
  assert.equal((await call('POST', '/v1/turn', { text: 'hi', requestId: 'plugin-server-0001' })).status, 200);
  const snapshot = await until(async () => (await call('GET', '/v1/session')).body, s => s.status === 'idle' && s.output, 'the answer');
  assert.equal(snapshot.output, 'echo: hi');
  assert.equal(snapshot.runtime, 'echo-agent');
  assert.equal((await call('POST', '/v1/runtime', { runtime: 'gpt' })).status, 400);
  assert.equal((await call('POST', '/v1/runtime', { runtime: 'echo-agent' })).status, 200);
});
