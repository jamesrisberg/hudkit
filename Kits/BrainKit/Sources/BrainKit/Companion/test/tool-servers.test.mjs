import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { chmod, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import http from 'node:http';
import net from 'node:net';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Session } from '../session.mjs';
import { CodexRuntime } from '../runtimes/codex.mjs';
import { ClaudeRuntime, PERMISSION_TOOL } from '../runtimes/claude.mjs';
import { allowedToolPatterns, claudeMcpServers, codexConfigArgs, parseToolServers, tomlString, withHostContext } from '../tool-servers.mjs';
import { loadHostFiles, parseArguments } from '../server.mjs';
import { voiceInstructions } from '../voice-instructions.mjs';

const FAKE_CODEX = fileURLToPath(new URL('./fixtures/fake-codex.mjs', import.meta.url));
const FAKE_CLAUDE = fileURLToPath(new URL('./fixtures/fake-claude.mjs', import.meta.url));
const SERVER = fileURLToPath(new URL('../server.mjs', import.meta.url));

const MACHUD = { name: 'machud', command: '/Apps/MacHUD.app/Contents/Helpers/machud-mcp', arguments: [], environment: { MACHUD_SOCKET: '/tmp/machud "dev".sock' }, requireApproval: false };
const NOTES = { name: 'notes-2', command: '/usr/local/bin/notes mcp', arguments: ['--stdio', 'a\\b'], environment: {}, requireApproval: true };

async function scratch(t, prefix) {
  const directory = await realpath(await mkdtemp(path.join(tmpdir(), prefix)));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}
async function until(read, predicate, what = 'condition') {
  const deadline = Date.now() + 5000;
  for (;;) {
    const value = await read();
    if (predicate(value)) return value;
    if (Date.now() > deadline) throw new Error(`Timed out waiting for ${what}: ${JSON.stringify(value)}`);
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}
const flag = (args, name) => args[args.indexOf(name) + 1];
const lines = async file => (await readFile(file, 'utf8')).trim().split('\n').map(line => JSON.parse(line));

test('tool servers are validated exactly: names, commands, arguments, environment, approval', () => {
  assert.deepEqual(parseToolServers([{ name: 'machud', command: '/bin/x' }]),
    [{ name: 'machud', command: '/bin/x', arguments: [], environment: {}, requireApproval: false }]);
  assert.deepEqual(parseToolServers([MACHUD, NOTES]), [MACHUD, NOTES]);
  const rejects = (value, pattern) => assert.throws(() => parseToolServers(value), pattern);
  rejects({}, /JSON array/);
  rejects([{ name: 'mac hud', command: '/bin/x' }], /letters, digits/);
  rejects([{ name: 'a.b', command: '/bin/x' }], /letters, digits/);
  rejects([{ name: 'brainkit_permissions', command: '/bin/x' }], /reserved/);
  rejects([{ name: 'x', command: '/bin/x' }, { name: 'x', command: '/bin/y' }], /used twice/);
  rejects([{ name: 'x', command: '' }], /needs a command/);
  rejects([{ name: 'x', command: '/bin/x\nrm' }], /needs a command/);
  rejects([{ name: 'x', command: '/bin/x', arguments: [1] }], /arguments/);
  rejects([{ name: 'x', command: '/bin/x', environment: { 'BAD-NAME': 'v' } }], /environment/);
  rejects([{ name: 'x', command: '/bin/x', environment: { OK: 1 } }], /environment/);
  rejects([{ name: 'x', command: '/bin/x', requireApproval: 'no' }], /requireApproval/);
  rejects([{ name: 'x', command: '/bin/x', cwd: '/' }], /unknown keys: cwd/);
});

test('Codex gets one -c override per setting, as TOML, with its approval mode', () => {
  assert.deepEqual(codexConfigArgs([MACHUD, NOTES]), [
    '-c', 'mcp_servers.machud.command="/Apps/MacHUD.app/Contents/Helpers/machud-mcp"',
    '-c', 'mcp_servers.machud.args=[]',
    '-c', 'mcp_servers.machud.env={ "MACHUD_SOCKET" = "/tmp/machud \\"dev\\".sock" }',
    '-c', 'mcp_servers.machud.default_tools_approval_mode="approve"',
    '-c', 'mcp_servers.notes-2.command="/usr/local/bin/notes mcp"',
    '-c', 'mcp_servers.notes-2.args=["--stdio", "a\\\\b"]',
    '-c', 'mcp_servers.notes-2.default_tools_approval_mode="prompt"',
  ]);
  assert.equal(tomlString('tab\there\u007f'), '"tab\\there\\u007F"');
  assert.deepEqual(codexConfigArgs([]), []);
});

test('Claude gets mcpServers entries and pre-allows only servers that need no approval', () => {
  assert.deepEqual(claudeMcpServers([MACHUD, NOTES]), {
    machud: { type: 'stdio', command: MACHUD.command, args: [], env: MACHUD.environment },
    'notes-2': { type: 'stdio', command: NOTES.command, args: NOTES.arguments, env: {} },
  });
  assert.deepEqual(allowedToolPatterns([MACHUD, NOTES]), ['mcp__machud__*']);
  assert.equal(withHostContext('Voice.', '  \n'), 'Voice.');
  assert.equal(withHostContext('Voice.', '# MacHUD\nUse the tools.\n'), 'Voice.\n\n# MacHUD\nUse the tools.');
});

test('the Codex runtime launches app-server with the overrides and turns MCP tool-call approvals into approvals', async t => {
  const directory = await scratch(t, 'brainkit-codex-tools-');
  const log = path.join(directory, 'codex.jsonl');
  process.env.FAKE_CODEX_LOG = log;
  t.after(() => { delete process.env.FAKE_CODEX_LOG; });
  const runtime = new CodexRuntime({ executable: FAKE_CODEX, toolServers: [MACHUD, NOTES] });
  t.after(() => runtime.close());
  const instructions = withHostContext(voiceInstructions(), '# MacHUD\nYou drive MacHUD.');
  const session = new Session({ runtime, cwd: directory, instructions, toolServers: [MACHUD, NOTES] });
  await session.initialize();
  const [launch, start] = await lines(log);
  assert.deepEqual(launch.args, ['app-server', ...codexConfigArgs([MACHUD, NOTES])]);
  assert.equal(start.method, 'thread/start');
  assert.match(start.developerInstructions, /^You are a capable personal voice assistant[\s\S]*\n\n# MacHUD\nYou drive MacHUD\.$/);
  assert.deepEqual(session.snapshot().toolServers, { names: ['machud', 'notes-2'], active: true, note: null });

  await session.submit('Make a tool call', 'codex-tools-000001');
  const waiting = await until(() => session.snapshot(), s => s.status === 'approval', 'the tool approval');
  assert.deepEqual({ ...waiting.approvals[0], id: 'x' }, { id: 'x', kind: 'tool', reason: 'Allow the machud MCP server to run tool "apply_loadout"?', command: 'machud: Apply loadout', cwd: null });
  session.approve(waiting.approvals[0].id, 'accept');
  let done = await until(() => session.snapshot(), s => s.status === 'idle' && s.turnId === 'turn-1', 'the accepted call');
  assert.equal(done.output, 'Tool accept {}');

  await session.submit('Make a tool call with no turn id', 'codex-tools-000002');
  const second = await until(() => session.snapshot(), s => s.status === 'approval', 'the second tool approval');
  session.approve(second.approvals[0].id, 'decline');
  done = await until(() => session.snapshot(), s => s.status === 'idle' && s.turnId === 'turn-2', 'the declined call');
  assert.equal(done.output, 'Tool decline');

  // An elicitation from a server the host did not configure is refused, never shown.
  await session.submit('Make a foreign tool call', 'codex-tools-000003');
  done = await until(() => session.snapshot(), s => s.status === 'idle' && s.turnId === 'turn-3', 'the refused call');
  assert.match(done.output, /^Refused: This client does not support this request/);
  assert.deepEqual(done.approvals, []);
});

test('the Claude runtime adds the tool servers to --mcp-config, --allowedTools and the appended prompt', async t => {
  const directory = await scratch(t, 'brainkit-claude-tools-');
  const log = path.join(directory, 'claude.jsonl');
  const runtime = new ClaudeRuntime({ executable: FAKE_CLAUDE, killGrace: 500, env: { ...process.env, FAKE_CLAUDE_LOG: log }, toolServers: [MACHUD, NOTES] });
  t.after(() => runtime.close());
  const instructions = withHostContext(voiceInstructions(), '# MacHUD\nYou drive MacHUD.');
  const session = new Session({ runtime, cwd: directory, instructions, toolServers: [MACHUD, NOTES] });
  await session.initialize();
  // The permission bridge still works with tool servers beside it.
  await session.submit('approve it', 'claude-tools-000001');
  const waiting = await until(() => session.snapshot(), s => s.status === 'approval', 'the bridge approval');
  session.approve(waiting.approvals[0].id, 'accept');
  await until(() => session.snapshot(), s => s.status === 'idle', 'the turn');
  const [call] = await lines(log);
  const config = JSON.parse(flag(call.args, '--mcp-config'));
  assert.deepEqual(Object.keys(config.mcpServers), ['brainkit_permissions', 'machud', 'notes-2']);
  assert.deepEqual(config.mcpServers.machud, { type: 'stdio', command: MACHUD.command, args: [], env: MACHUD.environment });
  assert.deepEqual(config.mcpServers['notes-2'], { type: 'stdio', command: NOTES.command, args: NOTES.arguments, env: {} });
  const allowed = call.args.indexOf('--allowedTools');
  assert.deepEqual(call.args.slice(allowed, allowed + 3), ['--allowedTools', 'mcp__machud__*', '--permission-prompt-tool']);
  assert.equal(flag(call.args, '--permission-prompt-tool'), PERMISSION_TOOL);
  assert.match(flag(call.args, '--append-system-prompt'), /\n\n# MacHUD\nYou drive MacHUD\.$/);
});

test('without tool servers Claude gets no --allowedTools and only the permission bridge', async t => {
  const directory = await scratch(t, 'brainkit-claude-plain-');
  const log = path.join(directory, 'claude.jsonl');
  const runtime = new ClaudeRuntime({ executable: FAKE_CLAUDE, killGrace: 500, env: { ...process.env, FAKE_CLAUDE_LOG: log } });
  t.after(() => runtime.close());
  const session = new Session({ runtime, cwd: directory });
  await session.initialize();
  await session.submit('hello', 'claude-plain-0000001');
  await until(() => session.snapshot(), s => s.status === 'idle' && s.output, 'the turn');
  const [call] = await lines(log);
  assert.ok(!call.args.includes('--allowedTools'));
  assert.deepEqual(Object.keys(JSON.parse(flag(call.args, '--mcp-config')).mcpServers), ['brainkit_permissions']);
  assert.deepEqual(session.snapshot().toolServers, { names: [], active: false, note: null });
});

test('the host files must be private and valid; the flags parse', async t => {
  const directory = await scratch(t, 'brainkit-host-files-');
  const servers = path.join(directory, 'tool-servers.json');
  const context = path.join(directory, 'host-context.md');
  await writeFile(servers, JSON.stringify([MACHUD]), { mode: 0o600 });
  await writeFile(context, '\n# MacHUD\n\n', { mode: 0o600 });
  const options = parseArguments(['--cwd', directory, '--tool-servers', servers, '--host-context', context]);
  assert.deepEqual(await loadHostFiles(options), { toolServers: [MACHUD], hostContext: '# MacHUD' });
  assert.deepEqual(await loadHostFiles({}), { toolServers: [], hostContext: '' });
  await chmod(servers, 0o644);
  await assert.rejects(loadHostFiles(options), /--tool-servers: .*private/);
  await writeFile(servers, '[{"name":"bad name","command":"/x"}]', { mode: 0o600 });
  await chmod(servers, 0o600);
  await assert.rejects(loadHostFiles(options), /Invalid tool servers/);
  await writeFile(servers, 'not json');
  await assert.rejects(loadHostFiles(options), /--tool-servers: /);
  await writeFile(servers, '[]');
  await writeFile(context, 'x'.repeat(65537));
  await assert.rejects(loadHostFiles(options), /at most 65536/);
});

async function freePort() {
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  await new Promise(resolve => server.close(resolve));
  return port;
}

test('the companion reads --tool-servers and --host-context and reports them in the snapshot', async t => {
  const directory = await scratch(t, 'brainkit-companion-tools-');
  const state = path.join(directory, 'state');
  const servers = path.join(directory, 'tool-servers.json');
  const context = path.join(directory, 'host-context.md');
  const log = path.join(directory, 'codex.jsonl');
  await writeFile(servers, JSON.stringify([MACHUD]), { mode: 0o600 });
  await writeFile(context, '# MacHUD\nYou drive MacHUD.', { mode: 0o600 });
  const port = await freePort();
  const child = spawn(process.execPath, [SERVER, '--cwd', directory, '--state-dir', state, '--port', String(port), '--codex', FAKE_CODEX,
    '--assistant-name', 'Jarvis', '--tool-servers', servers, '--host-context', context, '--runtime', 'codex'],
  { env: { ...process.env, FAKE_CODEX_LOG: log }, stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(() => child.kill('SIGTERM'));
  let output = '';
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { output += chunk; });
  await until(() => output, text => text.includes('Brain companion ready at'), 'the companion');
  const [launch, start] = await lines(log);
  assert.deepEqual(launch.args, ['app-server', ...codexConfigArgs([MACHUD])]);
  assert.match(start.developerInstructions, /^You are Jarvis, a capable[\s\S]*\n\n# MacHUD\nYou drive MacHUD\.$/);
  const token = (await readFile(path.join(state, 'token'), 'utf8')).trim();
  const snapshot = await new Promise((resolve, reject) => http.get({ host: '127.0.0.1', port, path: '/v1/session', headers: { Authorization: `Bearer ${token}` } }, response => {
    let data = ''; response.on('data', chunk => { data += chunk; }); response.on('end', () => resolve(JSON.parse(data)));
  }).on('error', reject));
  assert.deepEqual(snapshot.toolServers, { names: ['machud'], active: true, note: null });
});
