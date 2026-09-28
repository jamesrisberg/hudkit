#!/usr/bin/env node
// A stand-in for `codex app-server`: newline-delimited JSON-RPC over stdio with the
// request, notification and server-request shapes the Codex adapter relies on.
const send = message => process.stdout.write(JSON.stringify(message) + '\n');
const notify = (method, params) => send({ method, params: { threadId: 'thread-A', ...params } });
let turn = 0; let active = null;
let buffer = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  buffer += chunk; let newline;
  while ((newline = buffer.indexOf('\n')) >= 0) {
    const message = JSON.parse(buffer.slice(0, newline)); buffer = buffer.slice(newline + 1);
    handle(message);
  }
});
function handle({ id, method, params, result }) {
  if (method === undefined && id === 'approve-1') {
    // The client's answer to our approval request, then the turn finishes.
    const text = result.decision === 'accept' ? 'Ran it.' : 'Skipped it.';
    notify('item/completed', { turnId: active, item: { id: 'msg', type: 'agentMessage', text, phase: 'final_answer' } });
    notify('turn/completed', { turn: { id: active, status: 'completed', items: [{ id: 'msg', type: 'agentMessage', text, phase: 'final_answer' }] } });
    return;
  }
  if (method === 'initialize') return send({ id, result: { userAgent: 'fake-codex/0' } });
  if (method === 'initialized') return;
  if (method === 'thread/start' || method === 'thread/resume') return send({ id, result: { thread: { id: 'thread-A', turns: [] } } });
  if (method === 'model/list') return send({ id, result: { data: [{ model: 'gpt-5.6-luna', supportedReasoningEfforts: [{ reasoningEffort: 'low' }] }, { model: 'gpt-6-astra', supportedReasoningEfforts: [{ reasoningEffort: 'medium' }] }] } });
  if (method === 'turn/start') {
    active = `turn-${++turn}`;
    send({ id, result: { turn: { id: active } } });
    notify('turn/started', { turn: { id: active } });
    notify('item/started', { turnId: active, item: { id: 'cmd', type: 'commandExecution', command: 'ls -la' } });
    notify('item/agentMessage/delta', { turnId: active, itemId: 'msg', delta: 'Working on it' });
    const text = params.input[0].text;
    if (text.includes('approval')) send({ id: 'approve-1', method: 'item/commandExecution/requestApproval', params: { threadId: 'thread-A', turnId: active, itemId: 'cmd', command: 'touch /outside/file', cwd: '/workspace', reason: 'Write outside the workspace?' } });
    else if (!text.includes('wait')) notify('turn/completed', { turn: { id: active, status: 'completed', items: [{ id: 'msg', type: 'agentMessage', text: `Echo: ${text}`, phase: 'final_answer' }] } });
    return;
  }
  if (method === 'turn/interrupt') {
    send({ id, result: {} });
    notify('turn/completed', { turn: { id: params.turnId, status: 'interrupted', items: [] } });
    return;
  }
  send({ id, error: { code: -32601, message: `unknown ${method}` } });
}
