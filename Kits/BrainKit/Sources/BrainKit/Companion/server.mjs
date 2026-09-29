import http from 'node:http';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { mkdir, open, rename, realpath, unlink } from 'node:fs/promises';
import { constants } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { createRuntime, RUNTIME_IDS } from './runtimes/index.mjs';
import { Session } from './session.mjs';
import { voiceInstructions } from './voice-instructions.mjs';

async function privateRead(file) {
  const handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o077)) throw new Error(`${file} must be a private, user-owned regular file (chmod 600)`);
    return await handle.readFile('utf8');
  } finally { await handle.close(); }
}
export async function loadToken(directory) {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const file = path.join(directory, 'token');
  try {
    const handle = await open(file, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try { await handle.writeFile(randomBytes(32).toString('hex') + '\n'); } finally { await handle.close(); }
  } catch (error) { if (error.code !== 'EEXIST') throw error; }
  const token = (await privateRead(file)).trim();
  if (!/^[a-f0-9]{64}$/.test(token)) throw new Error('Invalid companion token file');
  return token;
}
export async function saveState(directory, state) {
  const temp = path.join(directory, `session.${randomBytes(8).toString('hex')}.tmp`);
  const handle = await open(temp, 'wx', 0o600);
  try {
    try { await handle.writeFile(JSON.stringify(state)); await handle.sync(); } finally { await handle.close(); }
    await rename(temp, path.join(directory, 'session.json'));
  } catch (error) {
    // Never leave partial state files behind in the private state directory.
    await unlink(temp).catch(() => {});
    throw error;
  }
}
function json(response, status, value) {
  response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  response.end(JSON.stringify(value));
}
async function body(request) {
  if (request.headers['content-type'] !== 'application/json') throw Object.assign(new Error('Content-Type must be application/json'), { status: 415 });
  let length = 0; const chunks = [];
  for await (const chunk of request) {
    length += chunk.length;
    if (length > 32768) throw Object.assign(new Error('Request too large'), { status: 413 });
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw Object.assign(new Error('Invalid JSON'), { status: 400 }); }
}
function exactObject(value, keys) {
  return value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).every(key => keys.includes(key));
}
export function createServer({ session, token }) {
  return http.createServer({ requestTimeout: 10000, headersTimeout: 10000, maxHeaderSize: 8192 }, async (request, response) => {
    // Native client only: browser origins are rejected even with a valid token.
    const port = request.socket.localPort;
    if (request.headers.host !== `127.0.0.1:${port}` || request.headers.origin !== undefined || request.headers['sec-fetch-site'] !== undefined) return json(response, 403, { error: 'Only the native loopback client is allowed' });
    const supplied = Buffer.from(request.headers.authorization ?? '');
    const expected = Buffer.from(`Bearer ${token}`);
    if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) return json(response, 401, { error: 'Invalid companion token' });
    try {
      if (request.method === 'GET' && request.url === '/v1/session') return json(response, 200, session.snapshot());
      if (request.method !== 'POST') return json(response, 404, { error: 'Not found' });
      const value = await body(request);
      if (request.url === '/v1/turn' && exactObject(value, ['text', 'requestId']) && typeof value.text === 'string' && value.text.trim() && value.text.length <= 16000 && typeof value.requestId === 'string' && /^[a-zA-Z0-9-]{16,80}$/.test(value.requestId)) return json(response, 200, await session.submit(value.text, value.requestId));
      if (request.url === '/v1/approval' && exactObject(value, ['id', 'decision']) && typeof value.id === 'string' && ['accept', 'decline'].includes(value.decision)) return json(response, 200, session.approve(value.id, value.decision));
      if (request.url === '/v1/permissions' && exactObject(value, ['mode', 'approvedFolders'])) return json(response, 200, await session.setPermissions(value));
      if (request.url === '/v1/cancel' && exactObject(value, []) ) return json(response, 200, await session.cancel());
      if (request.url === '/v1/session/reset' && exactObject(value, [])) return json(response, 200, await session.reset());
      if (request.url === '/v1/runtime' && exactObject(value, ['runtime']) && RUNTIME_IDS.includes(value.runtime)) return json(response, 200, await session.switchRuntime(value.runtime));
      json(response, 400, { error: 'Invalid request' });
    } catch (error) { json(response, error.status ?? 503, { error: String(error.message).slice(0, 2048) }); }
  });
}
const USAGE = 'Usage: node server.mjs --cwd /absolute/workspace [--runtime codex|hermes|claude|mclaude] [--state-dir /path] [--port 8788]\n' +
  '  [--codex /path/to/codex] [--claude /path/to/claude] [--mclaude /path/to/mclaude] [--runtime-url http://127.0.0.1:8642] [--runtime-token TOKEN | --runtime-token-file /path]\n' +
  '  [--assistant-name NAME]';
const FLAGS = ['--cwd', '--state-dir', '--codex', '--claude', '--mclaude', '--port', '--runtime', '--runtime-url', '--runtime-token', '--runtime-token-file', '--assistant-name'];
export function parseArguments(args) {
  const options = {};
  for (let i = 0; i < args.length; i += 2) {
    if (!FLAGS.includes(args[i]) || !args[i + 1] || options[args[i]] !== undefined) throw new Error(USAGE);
    options[args[i]] = args[i + 1];
  }
  if (options['--runtime'] !== undefined && !RUNTIME_IDS.includes(options['--runtime'])) throw new Error(`--runtime must be one of: ${RUNTIME_IDS.join(', ')}`);
  if (options['--runtime-token'] && options['--runtime-token-file']) throw new Error('Use either --runtime-token or --runtime-token-file');
  if (options['--assistant-name'] !== undefined && !/^[^\n\r]{1,64}$/.test(options['--assistant-name'])) throw new Error('--assistant-name must be one line of at most 64 characters');
  return options;
}
async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (!options['--cwd'] || !path.isAbsolute(options['--cwd'])) throw new Error('--cwd must name an explicit absolute workspace directory');
  const cwd = await realpath(options['--cwd']);
  const directory = path.resolve(options['--state-dir'] ?? path.join(homedir(), '.brainkit-companion'));
  const port = Number(options['--port'] ?? 8788);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid port');
  const token = await loadToken(directory);
  let saved = {};
  try { saved = JSON.parse(await privateRead(path.join(directory, 'session.json'))); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (saved.cwd && saved.cwd !== cwd) throw new Error('This state directory belongs to another workspace. Use a separate --state-dir.');
  // A token file keeps the Hermes key out of the process list; --runtime-token is for quick tests.
  const runtimeToken = options['--runtime-token-file'] ? (await privateRead(path.resolve(options['--runtime-token-file']))).trim() : options['--runtime-token'] ?? process.env.BRAINKIT_RUNTIME_TOKEN;
  // The explicit flag wins; otherwise the choice last made (flag or app) persists in the state directory.
  const runtimeName = options['--runtime'] ?? (RUNTIME_IDS.includes(saved.runtime) ? saved.runtime : 'codex');
  const runtimeOptions = { codex: options['--codex'], claude: options['--claude'], mclaude: options['--mclaude'], runtimeUrl: options['--runtime-url'], runtimeToken };
  const build = name => createRuntime(name, runtimeOptions);
  const session = new Session({ runtime: build(runtimeName), cwd, saved, createRuntime: build, instructions: voiceInstructions(options['--assistant-name']), save: state => saveState(directory, { ...state, cwd }) });
  const server = createServer({ session, token });
  // Bind before creating a thread: a second companion on this port must not create work.
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  const stop = () => { session.runtime.close(); server.closeAllConnections(); server.close(); };
  process.on('SIGINT', stop); process.on('SIGTERM', stop);
  // Started by the app: the app holds our stdin open, so end-of-file means it quit or
  // crashed. Exit rather than keep the port and the agent running without it.
  if (process.env.BRAINKIT_PARENT_PIPE === '1') {
    const orphaned = () => { stop(); setTimeout(() => process.exit(0), 3000).unref(); };
    process.stdin.on('end', orphaned); process.stdin.on('error', orphaned); process.stdin.resume();
    // The open stdin would keep the process alive after a normal SIGTERM/SIGINT stop.
    const release = () => process.stdin.destroy();
    process.on('SIGINT', release); process.on('SIGTERM', release);
  }
  try { await session.initialize(); }
  catch (error) {
    // Unsafe saved permissions stay fatal. An unreachable runtime is reported to the app,
    // which can retry or choose another runtime with POST /v1/runtime.
    if (error.status === 400 || !session.listeners) { stop(); throw error; }
    session.update({ status: 'failed', error: String(error.message).slice(0, 16384), progress: `Unable to start ${session.runtime.displayName}` });
    process.stderr.write(`${session.runtime.displayName} runtime failed to start: ${error.message}\n`);
  }
  process.stdout.write(`Brain companion ready at http://127.0.0.1:${port}\nRuntime: ${session.runtime.id}\nWorkspace: ${cwd}\nToken file: ${path.join(directory, 'token')}\n`);
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main().catch(error => { process.stderr.write(error.message + '\n'); process.exit(1); });
