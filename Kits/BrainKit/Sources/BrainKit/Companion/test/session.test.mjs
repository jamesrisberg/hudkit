import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { Session } from '../session.mjs';
import { CodexRuntime } from '../runtimes/codex.mjs';

// A fake `codex app-server` JSON-RPC transport; the real CodexRuntime adapter runs on top.
class FakeRuntime extends EventEmitter {
  calls = []; replies = []; rejected = [];
  close() {}
  async request(method, params) {
    this.calls.push({ method, params });
    if (method === 'initialize') return {};
    if (method === 'thread/start' || method === 'thread/resume') return { thread: { id: params.threadId ?? 'thread-1', turns: [] } };
    if (method === 'turn/start') return { turn: { id: 'turn-1' } };
    return {};
  }
  send(value) { this.calls.push(value); }
  reply(id, result) { this.replies.push({ id, result }); }
  reject(id) { this.rejected.push(id); }
  notify(method, params) { this.emit('message', { method, params: { threadId: 'thread-1', ...params } }); }
}
async function setup(saved) {
  const runtime = new FakeRuntime(); const writes = [];
  const session = new Session({ runtime: new CodexRuntime({ transport: runtime }), cwd: '/workspace', saved, save: async value => writes.push(value) });
  await session.initialize();
  return { runtime, session, writes };
}
test('persistent thread, sandbox, idempotent turn and snapshot reconnect', async () => {
  const { runtime, session, writes } = await setup({ threadId: 'thread-1' });
  assert.equal(runtime.calls[2].method, 'thread/resume');
  assert.equal(runtime.calls[2].params.approvalPolicy, 'on-request');
  assert.equal(runtime.calls[2].params.approvalsReviewer, 'user');
  assert.equal(runtime.calls[2].params.sandbox, 'workspace-write');
  await session.submit('create note', 'request-1');
  const call = runtime.calls.at(-1);
  assert.equal(call.params.threadId, 'thread-1');
  assert.equal(call.params.sandboxPolicy.networkAccess, false);
  assert.deepEqual(call.params.sandboxPolicy.writableRoots, ['/workspace']);
  assert.ok(writes.at(-1).requestIds.includes('request-1'));
  await session.submit('create note', 'request-1');
  assert.equal(runtime.calls.filter(c => c.method === 'turn/start').length, 1);
  await assert.rejects(session.submit('another', 'request-2'), { status: 409 });
  runtime.notify('item/agentMessage/delta', { itemId: 'answer', delta: 'Created' });
  assert.equal(session.snapshot().output, 'Created');
  const copy = session.snapshot(); copy.output = 'malicious';
  assert.equal(session.snapshot().output, 'Created');
  runtime.notify('turn/completed', { turn: { id: 'turn-1', status: 'completed', items: [{ type: 'agentMessage', text: 'Done.', phase: 'final_answer' }] } });
  assert.equal(session.snapshot().status, 'idle');
  await session.submit('revise it', 'request-2');
  assert.equal(runtime.calls.at(-1).params.threadId, 'thread-1');
  assert.equal(session.snapshot().output, '');
});
test('approval maps opaque UI ID to actual runtime request once; cancel waits for acknowledgement', async () => {
  const { runtime, session } = await setup();
  await session.submit('write', 'request-1');
  runtime.emit('message', { id: 27, method: 'item/commandExecution/requestApproval', params: { threadId: 'thread-1', turnId: 'turn-1', command: 'touch /outside/note', reason: 'Outside workspace' } });
  const approval = session.snapshot().approvals[0];
  assert.equal(session.snapshot().status, 'approval');
  assert.equal(runtime.replies.length, 0);
  session.approve(approval.id, 'accept');
  assert.deepEqual(runtime.replies[0], { id: 27, result: { decision: 'accept' } });
  assert.throws(() => session.approve(approval.id, 'accept'), { status: 409 });
  await session.cancel();
  assert.equal(runtime.calls.at(-1).method, 'turn/interrupt');
  assert.equal(session.snapshot().status, 'running');
  runtime.notify('turn/completed', { turn: { id: 'turn-1', status: 'interrupted', items: [] } });
  assert.equal(session.snapshot().status, 'interrupted');
});
test('unsupported requests denied; disconnect leaves truthful failure', async () => {
  const { runtime, session } = await setup();
  runtime.emit('message', { id: 80, method: 'unknown/request', params: { threadId: 'thread-1' } });
  assert.deepEqual(runtime.rejected, [80]);
  runtime.emit('disconnect', new Error('Disconnected'));
  assert.equal(session.snapshot().status, 'failed');
  await assert.rejects(session.submit('do something', 'request-3'), { status: 503 });
});
test('persisted request IDs cannot replay after restart; new conversation blocked during active turn', async () => {
  const { runtime, session } = await setup({ threadId: 'thread-1', requestIds: ['request-1'] });
  await session.submit('do something twice', 'request-1');
  assert.equal(runtime.calls.filter(c => c.method === 'turn/start').length, 0);
  await session.submit('new turn', 'request-2');
  await assert.rejects(session.reset(), { status: 409 });
  runtime.notify('turn/completed', { turn: { id: 'turn-1', status: 'completed', items: [] } });
  await session.reset();
  assert.equal(session.snapshot().turnId, null);
  assert.equal(session.snapshot().output, '');
});
test('completed notification before start response does not resurrect the turn', async () => {
  const { runtime, session } = await setup();
  const original = runtime.request.bind(runtime);
  runtime.request = async (method, params) => {
    if (method === 'turn/start') runtime.notify('turn/completed', { turn: { id: 'turn-1', status: 'completed', items: [] } });
    return original(method, params);
  };
  await session.submit('fast', 'request-1');
  assert.equal(session.snapshot().status, 'idle');
});
test('a poll while submit awaits durable persistence can still show the previous completion', async () => {
  const { runtime, session } = await setup();
  await session.submit('first', 'request-1');
  runtime.notify('turn/completed', { turn: { id: 'turn-1', status: 'completed', items: [{ type: 'agentMessage', text: 'Old response' }] } });
  let release;
  session.save = () => new Promise(resolve => { release = resolve; });
  const pending = session.submit('second', 'request-2');
  // This is why the native client suppresses polling updates during POST and returns
  // the POST snapshot for exact turn correlation, even for instantaneous completion.
  assert.equal(session.snapshot().turnId, 'turn-1');
  assert.equal(session.snapshot().status, 'idle');
  runtime.request = async method => {
    assert.equal(method, 'turn/start');
    runtime.notify('turn/completed', { turn: { id: 'turn-2', status: 'completed', items: [{ type: 'agentMessage', text: 'New response' }] } });
    return { turn: { id: 'turn-2' } };
  };
  session.save = async () => {};
  release();
  const result = await pending;
  assert.equal(result.turnId, 'turn-2');
  assert.equal(result.status, 'idle');
  assert.equal(result.output, 'New response');
});
test('completed turn receipt reconciles when POST response is lost', async () => {
  const { runtime, session, writes } = await setup();
  const requestId = 'request-that-lost-response';
  runtime.request = async () => {
    runtime.notify('turn/completed', { turn: { id: 'new-turn', status: 'completed', items: [{ type: 'agentMessage', text: 'File created' }] } });
    return { turn: { id: 'new-turn' } };
  };
  // Deliberately ignore the POST result, as if its HTTP connection disappeared.
  await session.submit('create file', requestId);
  const reconciled = session.snapshot();
  assert.equal(reconciled.requestId, requestId);
  assert.equal(reconciled.turnId, 'new-turn');
  assert.equal(reconciled.status, 'idle');
  assert.equal(writes.at(-1).receipt.acceptedTurnId, 'new-turn');
});
test('restart infers accepted receipt after crash before start response; never attributes the previous turn', async () => {
  for (const [lastID, expectedRequestID] of [['old-turn', null], ['new-turn', 'pending-request']]) {
    const runtime = new FakeRuntime();
    const original = runtime.request.bind(runtime);
    runtime.request = async (method, params) => {
      if (method === 'thread/resume') return { thread: { id: 'thread-1', turns: [{ id: lastID, status: 'completed', items: [{ type: 'agentMessage', text: lastID }] }] } };
      return original(method, params);
    };
    const session = new Session({ runtime: new CodexRuntime({ transport: runtime }), cwd: '/workspace', saved: {
      threadId: 'thread-1', requestIds: ['pending-request'],
      receipt: { requestId: 'pending-request', previousTurnId: 'old-turn', acceptedTurnId: null }
    } });
    await session.initialize();
    assert.equal(session.snapshot().requestId, expectedRequestID);
    assert.equal(session.snapshot().turnId, lastID);
  }
});

async function permissionSetup(t) {
  const { mkdtemp, realpath, mkdir, rm } = await import('node:fs/promises');
  const root = await realpath(await mkdtemp('/private/tmp/brainkit-permission-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const cwd = root + '/workspace', extra = root + '/extra';
  await mkdir(cwd); await mkdir(extra);
  const runtime = new FakeRuntime(), writes = [];
  const session = new Session({ runtime: new CodexRuntime({ transport: runtime }), cwd, save: async value => writes.push(structuredClone(value)) });
  await session.initialize();
  return { runtime, session, writes, cwd, extra, root };
}
test('permission modes persist and override start, reset, resume, and every turn', async t => {
  const { runtime, session, writes, cwd, extra } = await permissionSetup(t);
  assert.deepEqual(session.snapshot().permissions, { mode: 'approvedFolders', approvedFolders: [cwd] });
  await session.setPermissions({ mode: 'fullAccess', approvedFolders: [cwd, extra] });
  await session.reset();
  assert.equal(runtime.calls.at(-1).params.sandbox, 'danger-full-access');
  assert.equal(runtime.calls.at(-1).params.approvalPolicy, 'never');
  await session.submit('full', 'full-request');
  assert.deepEqual(runtime.calls.at(-1).params.sandboxPolicy, { type: 'dangerFullAccess' });
  runtime.notify('turn/completed', { turn: { id: 'turn-1', status: 'completed', items: [] } });
  await session.setPermissions({ mode: 'approvedFolders', approvedFolders: [extra, cwd] });
  const restartedRuntime = new FakeRuntime();
  const restarted = new Session({ runtime: new CodexRuntime({ transport: restartedRuntime }), cwd, saved: writes.at(-1) });
  await restarted.initialize();
  const resumed = restartedRuntime.calls[2];
  assert.equal(resumed.method, 'thread/resume');
  assert.equal(resumed.params.sandbox, 'workspace-write');
  assert.deepEqual(resumed.params.config['sandbox_workspace_write.writable_roots'], [cwd, extra]);
  await restarted.submit('restricted', 'restricted-request');
  assert.equal(restartedRuntime.calls.at(-1).params.approvalPolicy, 'on-request');
  assert.deepEqual(restartedRuntime.calls.at(-1).params.sandboxPolicy.writableRoots, [cwd, extra]);
});
test('folders canonicalize symlinks, reject invalid scopes and cannot remove workspace', async t => {
  const { session, cwd, extra, root } = await permissionSetup(t);
  const { symlink, writeFile } = await import('node:fs/promises');
  const alias = root + '/alias'; await symlink(extra, alias);
  const file = root + '/file'; await writeFile(file, 'file');
  await session.setPermissions({ mode: 'approvedFolders', approvedFolders: [alias, cwd, extra] });
  assert.deepEqual(session.snapshot().permissions.approvedFolders, [cwd, extra]);
  for (const value of [
    { mode: 'invalid', approvedFolders: [cwd] }, { mode: 'fullAccess', approvedFolders: [] },
    { mode: 'approvedFolders', approvedFolders: [extra] }, { mode: 'fullAccess', approvedFolders: [cwd, file] },
    { mode: 'approvedFolders', approvedFolders: [cwd, 'relative'] },
    { mode: 'approvedFolders', approvedFolders: [cwd, root + '/missing'] },
    { mode: 'approvedFolders', approvedFolders: Array(33).fill(cwd) }
  ]) await assert.rejects(session.setPermissions(value), { status: 400 });
});
test('permission changes serialize against persistence, submissions and approvals; failed save preserves scope', async t => {
  const { runtime, session, cwd } = await permissionSetup(t);
  const full = { mode: 'fullAccess', approvedFolders: [cwd] };
  session.save = async () => { throw new Error('disk failure'); };
  await assert.rejects(session.setPermissions(full), /disk failure/);
  assert.equal(session.snapshot().permissions.mode, 'approvedFolders');
  let release; session.save = () => new Promise(resolve => { release = resolve; });
  const setting = session.setPermissions(full);
  await assert.rejects(session.submit('racing', 'race'), { status: 409 });
  await assert.rejects(session.setPermissions(full), { status: 409 });
  while (!release) await new Promise(resolve => setImmediate(resolve));
  release(); await setting; session.save = async () => {};
  await session.submit('work', 'work');
  await assert.rejects(session.setPermissions(full), { status: 409 });
  runtime.emit('message', { id: 30, method: 'item/commandExecution/requestApproval', params: { threadId: 'thread-1', turnId: 'turn-1', command: 'touch /outside/file' } });
  await assert.rejects(session.setPermissions(full), { status: 409 });
});
test('file action approvals do not grant scope; completed and stale requests cannot be approved', async () => {
  const { runtime, session } = await setup();
  await session.submit('edit', 'edit');
  const request = { method: 'item/fileChange/requestApproval', params: { threadId: 'thread-1', turnId: 'turn-1', itemId: 'patch' } };
  runtime.emit('message', { ...request, id: 40, params: { ...request.params, grantRoot: '/outside' } });
  const hinted = session.snapshot().approvals[0];
  session.approve(hinted.id, 'accept');
  assert.deepEqual(runtime.replies.at(-1), { id: 40, result: { decision: 'accept' } });
  assert.deepEqual(session.snapshot().permissions, { mode: 'approvedFolders', approvedFolders: ['/workspace'] });
  runtime.emit('message', { ...request, id: 41 });
  const id = session.snapshot().approvals[0].id;
  assert.throws(() => session.approve(id, 'acceptForSession'), { status: 400 });
  runtime.notify('turn/completed', { turn: { id: 'turn-1', status: 'completed', items: [] } });
  assert.deepEqual(runtime.replies.at(-1), { id: 41, result: { decision: 'decline' } });
  assert.throws(() => session.approve(id, 'accept'), { status: 409 });
  runtime.emit('message', { ...request, id: 42 });
  assert.ok(runtime.rejected.includes(42));
});

test('restart rejects a saved canonical folder replaced by a symlink before contacting Codex', async t => {
  const { session, writes, cwd, extra, root } = await permissionSetup(t);
  const { rm, symlink, mkdir } = await import('node:fs/promises');
  await session.setPermissions({ mode: 'approvedFolders', approvedFolders: [cwd, extra] });
  const saved = writes.at(-1);
  const unapproved = root + '/unapproved'; await mkdir(unapproved);
  await rm(extra, { recursive: true }); await symlink(unapproved, extra);
  const runtime = new FakeRuntime();
  const restarted = new Session({ runtime: new CodexRuntime({ transport: runtime }), cwd, saved });
  await assert.rejects(restarted.initialize(), /Saved approved folder now points somewhere else/);
  assert.equal(runtime.calls.length, 0);
  // A fresh explicit settings choice can intentionally select a symlink target.
  await session.setPermissions({ mode: 'approvedFolders', approvedFolders: [cwd, extra] });
  assert.deepEqual(session.snapshot().permissions.approvedFolders, [cwd, unapproved]);
});

test('routing sends one model turn, preserves thread and policy, and records response timing', async () => {
  const runtime = new FakeRuntime();
  const original = runtime.request.bind(runtime);
  runtime.request = async (method, params) => {
    if (method === 'model/list') {
      runtime.calls.push({method, params});
      return { data: ['gpt-6-astra', 'gpt-5.6-luna'].map(model => ({model, supportedReasoningEfforts:[{reasoningEffort:'low'},{reasoningEffort:'medium'}]})) };
    }
    return original(method, params);
  };
  const session = new Session({ runtime: new CodexRuntime({ transport: runtime }), cwd:'/workspace'});
  await session.initialize();
  await session.submit('Create a note called groceries', 'routed-1');
  let call = runtime.calls.at(-1);
  assert.equal(call.params.model, 'gpt-5.6-luna'); assert.equal(call.params.effort, 'low');
  assert.equal(call.params.approvalPolicy, 'on-request');
  runtime.notify('item/agentMessage/delta', {itemId:'a',delta:'Created.'});
  runtime.notify('turn/completed', {turn:{id:'turn-1',status:'completed',items:[]}});
  assert.ok(session.snapshot().timing.firstResponseMs >= 0);
  assert.ok(session.snapshot().timing.completedMs >= session.snapshot().timing.firstResponseMs);
  await session.submit('Debug the crash in that program', 'routed-2');
  call = runtime.calls.at(-1);
  assert.equal(call.params.model, 'gpt-6-astra'); assert.equal(call.params.effort, 'medium');
  assert.equal(call.params.threadId, 'thread-1');
  assert.equal(session.snapshot().timing.firstResponseMs, null);
  await session.submit('Debug the crash in that program', 'routed-2');
  assert.equal(runtime.calls.filter(c => c.method === 'turn/start').length, 2);
  assert.equal(runtime.calls.filter(c => c.method === 'model/list').length, 1);
});

test('routing never retries a rejected model turn with another model', async () => {
  const {runtime, session} = await setup();
  const original = runtime.request.bind(runtime);
  runtime.request = async (method, params) => { const result = await original(method,params); if (method === 'turn/start') throw new Error('Model unavailable'); return result; };
  await assert.rejects(session.submit('Hello', 'unavailable'), /Model unavailable/);
  await session.submit('Hello', 'unavailable');
  assert.equal(runtime.calls.filter(c => c.method === 'turn/start').length, 1);
});

test('catalog disconnect cannot leave the session ready', async () => {
  const runtime = new FakeRuntime(); const original = runtime.request.bind(runtime);
  runtime.request = async (method, params) => { if (method === 'model/list') {runtime.dead = true; throw new Error('Disconnected');} return original(method,params); };
  const session = new Session({ runtime: new CodexRuntime({ transport: runtime }),cwd:'/workspace'});
  await assert.rejects(session.initialize(), /Disconnected/);
  await assert.rejects(session.submit('Hello','after-disconnect'), {status:503});
});

test('restart preserves deep follow-up affinity without fabricating old route metadata; reset clears it', async () => {
  const runtime = new FakeRuntime(); const original = runtime.request.bind(runtime); const writes = [];
  runtime.request = async (method, params) => {
    if (method === 'model/list') return {data:['gpt-6-astra','gpt-5.6-luna'].map(model => ({model,supportedReasoningEfforts:[{reasoningEffort:'low'},{reasoningEffort:'medium'}]}))};
    return original(method, params);
  };
  const session = new Session({ runtime: new CodexRuntime({ transport: runtime }),cwd:'/workspace',saved:{threadId:'thread-1',lastRouteTier:'deep'},save:async value => writes.push(value)});
  await session.initialize();
  assert.equal(session.snapshot().route,null); assert.equal(session.snapshot().timing,null);
  await session.submit('Make it shorter','followup');
  assert.equal(runtime.calls.at(-1).params.model,'gpt-6-astra');
  assert.equal(writes.at(-1).lastRouteTier,'deep');
  assert.equal(writes.at(-2).lastRouteTier,'deep');
  runtime.notify('turn/completed',{turn:{id:'turn-1',status:'completed',items:[]}});
  await session.reset();
  assert.equal(writes.at(-1).lastRouteTier,null);
  await session.submit('Make it shorter','fresh-conversation');
  assert.equal(runtime.calls.at(-1).params.model,'gpt-5.6-luna');
  assert.equal(writes.at(-1).lastRouteTier,'fast');
});

test('a saved thread Codex never wrote to disk is replaced with a new one', async () => {
  const runtime = new FakeRuntime();
  const original = runtime.request.bind(runtime);
  runtime.request = async (method, params) => {
    if (method === 'thread/resume') { runtime.calls.push({ method, params }); throw new Error('no rollout found for thread id empty-thread'); }
    return original(method, params);
  };
  const writes = [];
  const session = new Session({ runtime: new CodexRuntime({ transport: runtime }), cwd: '/workspace', saved: { threadId: 'empty-thread' }, save: async value => writes.push(value) });
  await session.initialize();
  assert.deepEqual(runtime.calls.filter(c => c.method?.startsWith('thread/')).map(c => c.method), ['thread/resume', 'thread/start']);
  assert.equal(session.snapshot().threadId, 'thread-1');
  assert.notEqual(session.snapshot().status, 'failed');
});

test('other thread resume failures still fail the runtime', async () => {
  const runtime = new FakeRuntime();
  const original = runtime.request.bind(runtime);
  runtime.request = async (method, params) => {
    if (method === 'thread/resume') throw new Error('permission denied');
    return original(method, params);
  };
  const session = new Session({ runtime: new CodexRuntime({ transport: runtime }), cwd: '/workspace', saved: { threadId: 'thread-9' }, save: async () => {} });
  await session.initialize().catch(() => {});
  assert.equal(runtime.calls.filter(c => c.method === 'thread/start').length, 0);
});
