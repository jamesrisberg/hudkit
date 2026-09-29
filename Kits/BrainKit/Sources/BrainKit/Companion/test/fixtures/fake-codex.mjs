#!/usr/bin/env node
// A stand-in for `codex app-server`: newline-delimited JSON-RPC over stdio with the
// request, notification and server-request shapes the Codex adapter relies on.
// Its command line is appended to FAKE_CODEX_LOG when set.
import { appendFileSync } from 'node:fs';
if (process.env.FAKE_CODEX_LOG) appendFileSync(process.env.FAKE_CODEX_LOG, JSON.stringify({ args: process.argv.slice(2) }) + '\n');
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
function finish(text) {
  notify('item/completed', { turnId: active, item: { id: 'msg', type: 'agentMessage', text, phase: 'final_answer' } });
  notify('turn/completed', { turn: { id: active, status: 'completed', items: [{ id: 'msg', type: 'agentMessage', text, phase: 'final_answer' }] } });
}
function handle({ id, method, params, result, error }) {
  // The client's answer to an MCP tool-call approval (an elicitation); an error declines.
  if (method === undefined && id === 'tool-approve-1') return finish(error ? `Refused: ${error.message}` : `Tool ${result.action}${result.content ? ' ' + JSON.stringify(result.content) : ''}`);
  if (method === undefined && id === 'approve-1') {
    // The client's answer to our approval request, then the turn finishes.
    const text = result.decision === 'accept' ? 'Ran it.' : 'Skipped it.';
    notify('item/completed', { turnId: active, item: { id: 'msg', type: 'agentMessage', text, phase: 'final_answer' } });
    notify('turn/completed', { turn: { id: active, status: 'completed', items: [{ id: 'msg', type: 'agentMessage', text, phase: 'final_answer' }] } });
    return;
  }
  if (method === 'initialize') return send({ id, result: { userAgent: 'fake-codex/0' } });
  if (method === 'initialized') return;
  if (method === 'thread/start' || method === 'thread/resume') {
    if (process.env.FAKE_CODEX_LOG) appendFileSync(process.env.FAKE_CODEX_LOG, JSON.stringify({ method, developerInstructions: params.developerInstructions }) + '\n');
    return send({ id, result: { thread: { id: 'thread-A', turns: [] } } });
  }
  if (method === 'model/list') return send({ id, result: { data: [{ model: 'gpt-5.6-luna', supportedReasoningEfforts: [{ reasoningEffort: 'low' }] }, { model: 'gpt-6-astra', supportedReasoningEfforts: [{ reasoningEffort: 'medium' }] }] } });
  if (method === 'turn/start') {
    active = `turn-${++turn}`;
    send({ id, result: { turn: { id: active } } });
    notify('turn/started', { turn: { id: active } });
    notify('item/started', { turnId: active, item: { id: 'cmd', type: 'commandExecution', command: 'ls -la' } });
    notify('item/agentMessage/delta', { turnId: active, itemId: 'msg', delta: 'Working on it' });
    const text = params.input[0].text;
    if (text.includes('tool call')) {
      const server = text.includes('foreign') ? 'other' : 'machud';
      send({ id: 'tool-approve-1', method: 'mcpServer/elicitation/request', params: { threadId: 'thread-A', turnId: text.includes('no turn id') ? null : active, serverName: server, mode: 'form',
        _meta: { codex_approval_kind: 'mcp_tool_call', tool_title: 'Apply loadout' }, message: 'Allow the machud MCP server to run tool "apply_loadout"?', requestedSchema: { type: 'object', properties: {} } } });
    }
    else if (text.includes('approval')) send({ id: 'approve-1', method: 'item/commandExecution/requestApproval', params: { threadId: 'thread-A', turnId: active, itemId: 'cmd', command: 'touch /outside/file', cwd: '/workspace', reason: 'Write outside the workspace?' } });
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
