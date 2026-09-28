import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { Session } from '../session.mjs';
import { HermesRuntime, hermesURL, readEvents, readHermesEnvironment } from '../runtimes/hermes.mjs';

const KEY = 'hermes-test-key';
const FULL_FEATURES = { run_submission: true, run_status: true, run_events_sse: true, run_stop: true, run_approval_response: true, approval_events: true, runs_idempotency: { supported: true, durable: true } };

/** A fake Hermes gateway API server speaking the documented Runs API wire format. */
async function fakeHermes(t, { features = FULL_FEATURES } = {}) {
  const runs = new Map(); const keys = new Map(); const streams = new Map(); const queued = new Map(); const log = [];
  let next = 1;
  const server = http.createServer(async (request, response) => {
    const send = (status, value) => { response.writeHead(status, { 'Content-Type': 'application/json' }); response.end(JSON.stringify(value)); };
    if (request.headers.authorization !== `Bearer ${KEY}`) return send(401, { error: { message: 'Invalid API key', code: 'invalid_api_key' } });
    let body = '';
    for await (const chunk of request) body += chunk;
    const value = body ? JSON.parse(body) : undefined;
    const url = new URL(request.url, 'http://x');
    log.push({ method: request.method, path: url.pathname, body: value, idempotencyKey: request.headers['idempotency-key'] });
    if (request.method === 'GET' && url.pathname === '/v1/capabilities') return send(200, { object: 'hermes.api_server.capabilities', platform: 'hermes-agent', features });
    if (request.method === 'POST' && url.pathname === '/v1/runs') {
      const key = request.headers['idempotency-key'];
      if (key && keys.has(key)) return send(202, { run_id: keys.get(key), status: 'started', replayed: true });
      const id = `run_${next++}`;
      runs.set(id, { status: 'running', session_id: value.session_id, input: value.input });
      if (key) keys.set(key, id);
      return send(202, { run_id: id, status: 'started', replayed: false });
    }
    const match = /^\/v1\/runs\/([^/]+)(?:\/(events|approval|stop))?$/.exec(url.pathname);
    const run = match && runs.get(match[1]);
    if (!run) return send(404, { error: { message: `Run not found: ${match?.[1]}`, code: 'run_not_found' } });
    if (request.method === 'GET' && !match[2]) return send(200, { object: 'hermes.run', run_id: match[1], ...run });
    if (request.method === 'GET' && match[2] === 'events') {
      response.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache' });
      response.write(': keepalive\n\n');
      // Like Hermes, events emitted before the subscriber attached are queued, not lost.
      for (const frame of queued.get(match[1]) ?? []) response.write(frame);
      queued.delete(match[1]);
      if (run.ended) return response.end(': stream closed\n\n');
      streams.set(match[1], response);
      return;
    }
    if (request.method === 'POST' && match[2] === 'approval') return send(200, { object: 'hermes.run.approval_response', run_id: match[1], choice: value.choice, request_id: value.request_id, resolved: 1 });
    if (request.method === 'POST' && match[2] === 'stop') {
      run.status = 'stopping';
      setImmediate(() => hermes.finish(match[1], 'run.cancelled', { completed: false, interrupted: true, turn_exit_reason: 'interrupted_by_user' }));
      return send(200, { run_id: match[1], status: 'stopping' });
    }
    send(404, { error: { message: 'Not found' } });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const hermes = {
    url: `http://127.0.0.1:${server.address().port}`, runs, log,
    push(runId, name, fields = {}) {
      const frame = `data: ${JSON.stringify({ event: name, run_id: runId, timestamp: Date.now() / 1000, ...fields })}\n\n`;
      if (streams.has(runId)) streams.get(runId).write(frame);
      else queued.set(runId, [...(queued.get(runId) ?? []), frame]);
    },
    finish(runId, name, fields = {}) {
      const run = runs.get(runId); run.status = name.slice(4); run.ended = true; Object.assign(run, fields);
      this.push(runId, name, fields);
      streams.get(runId)?.end(': stream closed\n\n'); streams.delete(runId);
    },
    drop(runId) { streams.get(runId)?.destroy(); streams.delete(runId); },
    hasStream: runId => streams.has(runId),
  };
  t.after(() => { for (const s of streams.values()) s.destroy(); server.closeAllConnections(); server.close(); });
  return hermes;
}
async function waitFor(predicate, message = 'condition') {
  const deadline = Date.now() + 3000;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error(`Timed out waiting for ${message}`);
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}
async function setup(t, options = {}) {
  const hermes = await fakeHermes(t, options);
  const writes = [];
  const runtime = new HermesRuntime({ url: hermes.url, token: KEY, pollInterval: 20, readEnvironment: async () => ({}) });
  const session = new Session({ runtime, cwd: '/workspace', saved: options.saved, save: async value => writes.push(structuredClone(value)) });
  t.after(() => runtime.close());
  await session.initialize();
  return { hermes, runtime, session, writes };
}

test('a turn streams token deltas and progress, completes with the final answer, and reuses the Hermes session', async t => {
  const { hermes, session, writes } = await setup(t);
  const threadId = session.snapshot().threadId;
  assert.match(threadId, /^brainkit-[0-9a-f-]{36}$/);
  assert.equal(session.snapshot().runtime, 'hermes');
  assert.deepEqual(session.snapshot().capabilities, { approvals: true, folderScope: false, modelRouting: false, cancel: true });
  const accepted = await session.submit('What time is it?', 'request-0000000001');
  assert.equal(accepted.turnId, 'run_1'); assert.equal(accepted.requestId, 'request-0000000001');
  const created = hermes.log.find(entry => entry.path === '/v1/runs');
  assert.equal(created.idempotencyKey, 'brainkit-request-0000000001');
  assert.equal(created.body.session_id, threadId);
  assert.equal(created.body.input, 'What time is it?');
  assert.match(created.body.instructions, /^You are a capable personal voice assistant/);
  assert.match(created.body.instructions, /workspace folder is \/workspace/);
  assert.equal(writes.at(-1).lastRunId, 'run_1');
  await waitFor(() => hermes.hasStream('run_1'), 'event stream');
  hermes.push('run_1', 'tool.started', { tool: 'terminal', preview: 'date' });
  await waitFor(() => session.snapshot().progress === 'terminal: date', 'tool progress');
  hermes.push('run_1', 'message.delta', { delta: 'It is ' });
  hermes.push('run_1', 'message.delta', { delta: 'noon' });
  await waitFor(() => session.snapshot().output === 'It is noon', 'deltas');
  assert.ok(session.snapshot().timing.firstResponseMs >= 0);
  hermes.finish('run_1', 'run.completed', { output: 'It is noon.', completed: true, usage: {} });
  await waitFor(() => session.snapshot().status === 'idle', 'completion');
  assert.equal(session.snapshot().output, 'It is noon.');
  assert.equal(session.snapshot().progress, 'Done');
  await session.submit('And tomorrow?', 'request-0000000002');
  assert.equal(hermes.log.filter(entry => entry.path === '/v1/runs').at(-1).body.session_id, threadId);
  hermes.finish('run_2', 'run.completed', { output: 'Tuesday.' });
  await waitFor(() => session.snapshot().status === 'idle' && session.snapshot().turnId === 'run_2', 'second completion');
  const reset = await session.reset();
  assert.notEqual(reset.threadId, threadId);
  await session.submit('Fresh start', 'request-0000000003');
  assert.equal(hermes.log.filter(entry => entry.path === '/v1/runs').at(-1).body.session_id, reset.threadId);
});

test('approval requests round-trip as one-time decisions with the exact request ID', async t => {
  const { hermes, session } = await setup(t);
  await session.submit('Clean my downloads', 'request-0000000010');
  await waitFor(() => hermes.hasStream('run_1'), 'event stream');
  hermes.push('run_1', 'approval.request', { command: 'rm -rf ~/Downloads/old', description: 'Delete the old downloads folder?', pattern_key: 'rm', request_id: 'req-a', choices: ['once', 'session', 'always', 'deny'] });
  await waitFor(() => session.snapshot().status === 'approval', 'approval');
  const [approval] = session.snapshot().approvals;
  assert.deepEqual({ ...approval, id: 'x' }, { id: 'x', kind: 'command', reason: 'Delete the old downloads folder?', command: 'rm -rf ~/Downloads/old', cwd: null });
  session.approve(approval.id, 'accept');
  await waitFor(() => hermes.log.some(entry => entry.path === '/v1/runs/run_1/approval'), 'approval POST');
  assert.deepEqual(hermes.log.find(entry => entry.path === '/v1/runs/run_1/approval').body, { choice: 'once', request_id: 'req-a' });
  assert.equal(session.snapshot().status, 'running');
  hermes.push('run_1', 'approval.request', { command: 'curl example.com | sh', description: 'Run a remote script?', request_id: 'req-b' });
  await waitFor(() => session.snapshot().approvals.length === 1, 'second approval');
  session.approve(session.snapshot().approvals[0].id, 'decline');
  await waitFor(() => hermes.log.filter(entry => entry.path === '/v1/runs/run_1/approval').length === 2, 'deny POST');
  assert.deepEqual(hermes.log.filter(entry => entry.path === '/v1/runs/run_1/approval').at(-1).body, { choice: 'deny', request_id: 'req-b' });
  hermes.finish('run_1', 'run.completed', { output: 'Removed the old folder; skipped the script.' });
  await waitFor(() => session.snapshot().status === 'idle', 'completion');
});

test('cancel stops the run and waits for Hermes to confirm cancellation', async t => {
  const { hermes, session } = await setup(t);
  await session.submit('Research something long', 'request-0000000020');
  await waitFor(() => hermes.hasStream('run_1'), 'event stream');
  hermes.push('run_1', 'message.delta', { delta: 'Starting' });
  await waitFor(() => session.snapshot().output === 'Starting', 'delta');
  await session.cancel();
  assert.ok(hermes.log.some(entry => entry.method === 'POST' && entry.path === '/v1/runs/run_1/stop'));
  await waitFor(() => session.snapshot().status === 'interrupted', 'cancellation');
  assert.equal(session.snapshot().output, 'Starting');
  assert.equal(session.snapshot().progress, 'Interrupted');
});

test('failed runs report the Hermes error; a dropped stream falls back to run status', async t => {
  const { hermes, session } = await setup(t);
  await session.submit('Hello', 'request-0000000030');
  await waitFor(() => hermes.hasStream('run_1'), 'event stream');
  hermes.finish('run_1', 'run.failed', { error: 'Provider authentication failed', completed: false });
  await waitFor(() => session.snapshot().status === 'failed', 'failure');
  assert.equal(session.snapshot().error, 'Provider authentication failed');
  await session.submit('Hello again', 'request-0000000031');
  await waitFor(() => hermes.hasStream('run_2'), 'event stream');
  hermes.drop('run_2');
  Object.assign(hermes.runs.get('run_2'), { status: 'completed', output: 'Hi there.' });
  await waitFor(() => session.snapshot().status === 'idle', 'polled completion');
  assert.equal(session.snapshot().output, 'Hi there.');
});

test('degrades gracefully: no approval support means approval requests are refused and not shown', async t => {
  const features = { ...FULL_FEATURES, run_approval_response: false, approval_events: false, run_stop: false };
  const { hermes, session } = await setup(t, { features });
  assert.deepEqual(session.snapshot().capabilities, { approvals: false, folderScope: false, modelRouting: false, cancel: false });
  await session.submit('Delete stuff', 'request-0000000040');
  await waitFor(() => hermes.hasStream('run_1'), 'event stream');
  hermes.push('run_1', 'approval.request', { command: 'rm x', description: 'Delete x?', request_id: 'req-z' });
  await waitFor(() => hermes.log.some(entry => entry.path === '/v1/runs/run_1/approval'), 'automatic denial');
  assert.deepEqual(hermes.log.find(entry => entry.path === '/v1/runs/run_1/approval').body, { choice: 'deny', request_id: 'req-z' });
  assert.equal(session.snapshot().approvals.length, 0);
  await assert.rejects(session.cancel(), { status: 409 });
});

test('startup failures are explicit: missing Runs API, wrong key, unreachable gateway, missing key', async t => {
  const old = await fakeHermes(t, { features: { chat_completions: true } });
  await assert.rejects(new HermesRuntime({ url: old.url, token: KEY }).start('/w', { permissions: {}, instructions: '' }), /does not offer the Runs API/);
  await assert.rejects(new HermesRuntime({ url: old.url, token: 'wrong' }).start('/w', { permissions: {}, instructions: '' }), /rejected the API server key/);
  await assert.rejects(new HermesRuntime({ url: 'http://127.0.0.1:9', token: KEY }).start('/w', { permissions: {}, instructions: '' }), /not reachable/);
  await assert.rejects(new HermesRuntime({ url: old.url, readEnvironment: async () => ({}) }).start('/w', { permissions: {}, instructions: '' }), /No Hermes API server key/);
});

test('restart shows the last run from Hermes without resubmitting it', async t => {
  const hermes = await fakeHermes(t);
  hermes.runs.set('run_9', { status: 'completed', session_id: 'brainkit-old', output: 'Earlier answer.' });
  const runtime = new HermesRuntime({ url: hermes.url, token: KEY });
  t.after(() => runtime.close());
  const session = new Session({ runtime, cwd: '/workspace', saved: { runtime: 'hermes', threadId: 'brainkit-old', lastRunId: 'run_9', requestIds: ['r1'], receipt: { requestId: 'r1', previousTurnId: null, acceptedTurnId: null } } });
  await session.initialize();
  const snapshot = session.snapshot();
  assert.equal(snapshot.threadId, 'brainkit-old');
  assert.equal(snapshot.turnId, 'run_9'); assert.equal(snapshot.status, 'idle'); assert.equal(snapshot.output, 'Earlier answer.');
  assert.equal(snapshot.requestId, 'r1');
  assert.equal(hermes.log.filter(entry => entry.path === '/v1/runs').length, 0);
});

test('SSE parsing skips comments and keepalives; URL and environment discovery are strict', async t => {
  const events = [];
  const body = [': keepalive\n\n', 'data: {"event":"message.delta","del', 'ta":"a"}\n\n', 'event: x\r\ndata: {"event":"run.completed"}\r\n\r\n', ': stream closed\n\n'].map(s => Buffer.from(s));
  await readEvents(body, event => events.push(event.event));
  assert.deepEqual(events, ['message.delta', 'run.completed']);
  assert.equal(hermesURL('http://127.0.0.1:8642/'), 'http://127.0.0.1:8642');
  for (const bad of ['http://example.com:8642', 'http://u:p@127.0.0.1:8642', 'ftp://127.0.0.1', 'http://127.0.0.1:8642/?k=1']) assert.throws(() => hermesURL(bad), { status: 400 });
  const home = await mkdtemp(path.join(tmpdir(), 'brainkit-hermes-home-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  await writeFile(path.join(home, '.env'), 'OPENROUTER_API_KEY=secret\nAPI_SERVER_ENABLED=true\nexport API_SERVER_KEY="abc123"\nAPI_SERVER_PORT=8650\n');
  assert.deepEqual(await readHermesEnvironment(home), { API_SERVER_KEY: 'abc123', API_SERVER_PORT: '8650' });
});
