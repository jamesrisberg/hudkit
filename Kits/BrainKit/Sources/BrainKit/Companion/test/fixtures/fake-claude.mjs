#!/usr/bin/env node
// A stand-in for `claude -p --input-format stream-json --output-format stream-json`.
// It speaks the documented stream-json message shapes and, for approvals, really
// launches the MCP permission server named by --mcp-config and calls its tool.
import { spawn } from 'node:child_process';
import { appendFileSync } from 'node:fs';

const args = process.argv.slice(2);
if (args[0] === '--version') { console.log('2.1.999 (Claude Code)'); process.exit(0); }
if (process.env.FAKE_CLAUDE_LOG) appendFileSync(process.env.FAKE_CLAUDE_LOG, JSON.stringify({ args, hasToken: Boolean(process.env.BRAINKIT_APPROVAL_TOKEN), claudecode: process.env.CLAUDECODE ?? null }) + '\n');
const flag = name => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : null; };
const sessionId = flag('--resume') ?? flag('--session-id');
const out = message => process.stdout.write(JSON.stringify({ session_id: sessionId, ...message }) + '\n');
const delta = text => out({ type: 'stream_event', parent_tool_use_id: null, event: { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text } } });
const assistant = content => out({ type: 'assistant', parent_tool_use_id: null, message: { role: 'assistant', content } });
const result = (text, extra = {}) => out({ type: 'result', subtype: 'success', is_error: false, result: text, ...extra });

async function callPermissionTool(toolName, input) {
  const config = JSON.parse(flag('--mcp-config'));
  const [name, server] = Object.entries(config.mcpServers)[0];
  const tool = flag('--permission-prompt-tool');
  if (tool !== `mcp__${name}__approve`) throw new Error(`unexpected permission tool ${tool}`);
  const child = spawn(server.command, server.args, { env: { ...process.env, ...server.env }, stdio: ['pipe', 'pipe', 'inherit'] });
  let buffer = ''; const waiting = new Map(); let next = 1;
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', chunk => {
    buffer += chunk; let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const message = JSON.parse(buffer.slice(0, newline)); buffer = buffer.slice(newline + 1);
      waiting.get(message.id)?.(message); waiting.delete(message.id);
    }
  });
  const rpc = (method, params) => new Promise(resolve => { const id = next++; waiting.set(id, resolve); child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n'); });
  await rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'fake-claude', version: '0' } });
  child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
  const tools = await rpc('tools/list', {});
  if (tools.result.tools[0].name !== 'approve') throw new Error('approve tool missing');
  const response = await rpc('tools/call', { name: 'approve', arguments: { tool_name: toolName, input, tool_use_id: 'toolu_1' } });
  child.stdin.end();
  return JSON.parse(response.result.content[0].text);
}

let input = ''; let handled = false;
process.stdin.setEncoding('utf8');
process.stdin.on('data', async chunk => {
  input += chunk;
  if (handled || !input.includes('\n')) return;
  handled = true;
  const prompt = JSON.parse(input.slice(0, input.indexOf('\n'))).message.content;
  out({ type: 'system', subtype: 'init', cwd: process.cwd(), tools: ['Bash'], mcp_servers: [{ name: 'brainkit_permissions', status: 'connected' }], permissionMode: flag('--permission-mode') });
  if (prompt.startsWith('approve')) {
    assistant([{ type: 'tool_use', id: 'toolu_1', name: 'Bash', input: { command: 'rm -rf /tmp/demo', description: 'Delete the demo folder' } }]);
    const decision = await callPermissionTool('Bash', { command: 'rm -rf /tmp/demo', description: 'Delete the demo folder' });
    const text = decision.behavior === 'allow' ? `Allowed ${decision.updatedInput.command}` : `Denied: ${decision.message}`;
    assistant([{ type: 'text', text }]);
    result(text);
  } else if (prompt.startsWith('slow')) {
    delta('Once upon');
    process.on('SIGINT', () => { out({ type: 'result', subtype: 'error_during_execution', is_error: true, result: '' }); process.exit(130); });
    setTimeout(() => {}, 60000);
    return;
  } else if (prompt.startsWith('crash')) {
    process.stderr.write('fatal: something broke\n');
    process.exit(3);
  } else {
    out({ type: 'stream_event', parent_tool_use_id: null, event: { type: 'message_start' } });
    delta('Hello'); delta(' there');
    out({ type: 'stream_event', parent_tool_use_id: 'toolu_sub', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'subagent noise' } } });
    assistant([{ type: 'text', text: 'Hello there.' }]);
    result('Hello there.');
  }
});
process.stdin.on('end', () => setTimeout(() => process.exit(0), 10));
