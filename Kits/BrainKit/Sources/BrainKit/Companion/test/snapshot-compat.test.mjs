import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { Session } from '../session.mjs';
import { CodexRuntime } from '../runtimes/codex.mjs';
import { createServer } from '../server.mjs';

// Golden snapshots of one scripted Codex conversation, with instanceId/approval IDs/
// timestamps masked. Clients decode these bytes; new fields may only be appended
// after them (APPENDED).
const GOLDEN = [
  "{\"threadId\":\"thread-1\",\"turnId\":null,\"status\":\"idle\",\"output\":\"\",\"progress\":\"Ready\",\"approvals\":[],\"error\":null,\"revision\":1,\"instanceId\":\"X\",\"requestId\":null,\"route\":null,\"timing\":null,\"permissions\":{\"mode\":\"approvedFolders\",\"approvedFolders\":[\"/workspace\"]},\"routing\":{\"mode\":\"automatic\",\"available\":true,\"fastModel\":\"gpt-5.6-luna\",\"deepModel\":\"gpt-6-astra\"}}",
  "{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"status\":\"running\",\"output\":\"\",\"progress\":\"Thinking\",\"approvals\":[],\"error\":null,\"revision\":5,\"instanceId\":\"X\",\"requestId\":\"request-000000001\",\"route\":{\"tier\":\"fast\",\"model\":\"gpt-5.6-luna\",\"effort\":\"low\",\"reason\":\"Straightforward request\"},\"timing\":{\"startedAt\":\"N\",\"firstResponseMs\":null,\"completedMs\":null},\"permissions\":{\"mode\":\"approvedFolders\",\"approvedFolders\":[\"/workspace\"]},\"routing\":{\"mode\":\"automatic\",\"available\":true,\"fastModel\":\"gpt-5.6-luna\",\"deepModel\":\"gpt-6-astra\"}}",
  "{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"status\":\"approval\",\"output\":\"Creat\",\"progress\":\"Waiting for your approval\",\"approvals\":[{\"id\":\"A\",\"kind\":\"command\",\"reason\":\"Outside\",\"command\":\"touch /x\",\"cwd\":\"/workspace\"}],\"error\":null,\"revision\":8,\"instanceId\":\"X\",\"requestId\":\"request-000000001\",\"route\":{\"tier\":\"fast\",\"model\":\"gpt-5.6-luna\",\"effort\":\"low\",\"reason\":\"Straightforward request\"},\"timing\":{\"startedAt\":\"N\",\"firstResponseMs\":\"N\",\"completedMs\":null},\"permissions\":{\"mode\":\"approvedFolders\",\"approvedFolders\":[\"/workspace\"]},\"routing\":{\"mode\":\"automatic\",\"available\":true,\"fastModel\":\"gpt-5.6-luna\",\"deepModel\":\"gpt-6-astra\"}}",
  "{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"status\":\"running\",\"output\":\"Creat\",\"progress\":\"Permission granted once\",\"approvals\":[],\"error\":null,\"revision\":9,\"instanceId\":\"X\",\"requestId\":\"request-000000001\",\"route\":{\"tier\":\"fast\",\"model\":\"gpt-5.6-luna\",\"effort\":\"low\",\"reason\":\"Straightforward request\"},\"timing\":{\"startedAt\":\"N\",\"firstResponseMs\":\"N\",\"completedMs\":null},\"permissions\":{\"mode\":\"approvedFolders\",\"approvedFolders\":[\"/workspace\"]},\"routing\":{\"mode\":\"automatic\",\"available\":true,\"fastModel\":\"gpt-5.6-luna\",\"deepModel\":\"gpt-6-astra\"}}",
  "{\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"status\":\"idle\",\"output\":\"Created.\",\"progress\":\"Done\",\"approvals\":[],\"error\":null,\"revision\":12,\"instanceId\":\"X\",\"requestId\":\"request-000000001\",\"route\":{\"tier\":\"fast\",\"model\":\"gpt-5.6-luna\",\"effort\":\"low\",\"reason\":\"Straightforward request\"},\"timing\":{\"startedAt\":\"N\",\"firstResponseMs\":\"N\",\"completedMs\":\"N\"},\"permissions\":{\"mode\":\"approvedFolders\",\"approvedFolders\":[\"/workspace\"]},\"routing\":{\"mode\":\"automatic\",\"available\":true,\"fastModel\":\"gpt-5.6-luna\",\"deepModel\":\"gpt-6-astra\"}}",
  "{\"threadId\":\"thread-1\",\"turnId\":null,\"status\":\"idle\",\"output\":\"\",\"progress\":\"Ready\",\"approvals\":[],\"error\":null,\"revision\":13,\"instanceId\":\"X\",\"requestId\":null,\"route\":null,\"timing\":null,\"permissions\":{\"mode\":\"approvedFolders\",\"approvedFolders\":[\"/workspace\"]},\"routing\":{\"mode\":\"automatic\",\"available\":true,\"fastModel\":\"gpt-5.6-luna\",\"deepModel\":\"gpt-6-astra\"}}",
];
const APPENDED = ['runtime', 'capabilities'];

class FakeCodex extends EventEmitter {
  async request(method, params) {
    if (method === 'initialize') return {};
    if (method === 'thread/start' || method === 'thread/resume') return { thread: { id: params.threadId ?? 'thread-1', turns: [] } };
    if (method === 'turn/start') return { turn: { id: 'turn-1' } };
    if (method === 'model/list') return { data: ['gpt-6-astra', 'gpt-5.6-luna'].map(model => ({ model, supportedReasoningEfforts: [{ reasoningEffort: 'low' }, { reasoningEffort: 'medium' }] })) };
    return {};
  }
  send() {} reply() {} reject() {} close() {}
  notify(method, params) { this.emit('message', { method, params: { threadId: 'thread-1', ...params } }); }
}
const mask = s => ({ ...s, instanceId: 'X', timing: s.timing && Object.fromEntries(Object.entries(s.timing).map(([k, v]) => [k, v === null ? null : 'N'])), approvals: s.approvals.map(a => ({ ...a, id: 'A' })) });

test('HTTP snapshots keep the golden fields and bytes, with runtime fields appended', async t => {
  const codex = new FakeCodex();
  const session = new Session({ runtime: new CodexRuntime({ transport: codex }), cwd: '/workspace' });
  const token = 'b'.repeat(64);
  const server = createServer({ session, token });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const get = async () => {
    const response = await fetch(`http://127.0.0.1:${server.address().port}/v1/session`, { headers: { Authorization: `Bearer ${token}` } });
    return response.text();
  };
  const seen = [];
  const check = async () => {
    const value = JSON.parse(await get());
    assert.deepEqual(Object.keys(value).slice(-APPENDED.length), APPENDED);
    assert.equal(value.runtime, 'codex');
    assert.deepEqual(value.capabilities, { approvals: true, folderScope: true, modelRouting: true, cancel: true });
    for (const key of APPENDED) delete value[key];
    seen.push(JSON.stringify(mask(value)));
  };
  await session.initialize(); await check();
  await session.submit('Create a note called groceries', 'request-000000001'); await check();
  codex.notify('item/agentMessage/delta', { itemId: 'a', delta: 'Creat' });
  codex.emit('message', { id: 9, method: 'item/commandExecution/requestApproval', params: { threadId: 'thread-1', turnId: 'turn-1', command: 'touch /x', reason: 'Outside', cwd: '/workspace' } });
  await check();
  session.approve(session.snapshot().approvals[0].id, 'accept'); await check();
  codex.notify('turn/completed', { turn: { id: 'turn-1', status: 'completed', items: [{ type: 'agentMessage', text: 'Created.', phase: 'final_answer' }] } });
  await check();
  await session.reset(); await check();
  assert.deepEqual(seen, GOLDEN);
});
