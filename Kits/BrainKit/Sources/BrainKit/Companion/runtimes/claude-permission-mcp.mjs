#!/usr/bin/env node
// Minimal MCP stdio server that Claude Code launches for --permission-prompt-tool.
// It has one tool, `approve`, and forwards each permission request over a private
// Unix socket to the companion, which asks the user and answers with
// {"behavior":"allow","updatedInput":{...}} or {"behavior":"deny","message":"..."}.
// Zero dependencies: newline-delimited JSON-RPC 2.0 as in the MCP stdio transport.
import net from 'node:net';

const SOCKET = process.env.BRAINKIT_APPROVAL_SOCKET;
const TOKEN = process.env.BRAINKIT_APPROVAL_TOKEN;
const TOOL = {
  name: 'approve',
  description: 'Asks the user to allow or deny one tool call. Used only as the permission prompt tool.',
  inputSchema: { type: 'object', properties: { tool_name: { type: 'string' }, input: { type: 'object' }, tool_use_id: { type: 'string' } }, required: ['tool_name', 'input'] },
};
const deny = message => ({ behavior: 'deny', message });

function write(message) { process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n'); }

/** One request per connection; the companion answers once, or the socket closes (deny). */
function ask(args) {
  return new Promise(resolve => {
    if (!SOCKET || !TOKEN) return resolve(deny('The approval bridge is not configured.'));
    let buffer = ''; let settled = false;
    const finish = value => { if (!settled) { settled = true; socket.destroy(); resolve(value); } };
    const socket = net.connect(SOCKET, () => socket.write(JSON.stringify({ token: TOKEN, tool_name: args.tool_name, input: args.input, tool_use_id: args.tool_use_id ?? null }) + '\n'));
    socket.setEncoding('utf8');
    socket.on('data', chunk => {
      buffer += chunk;
      if (buffer.length > 1024 * 1024) return finish(deny('The approval response was too large.'));
      const newline = buffer.indexOf('\n');
      if (newline < 0) return;
      try {
        const decision = JSON.parse(buffer.slice(0, newline));
        if (decision.behavior === 'allow' && decision.updatedInput && typeof decision.updatedInput === 'object') finish({ behavior: 'allow', updatedInput: decision.updatedInput });
        else finish(deny(typeof decision.message === 'string' ? decision.message : 'The user denied this action.'));
      } catch { finish(deny('The approval response was invalid.')); }
    });
    socket.on('error', () => finish(deny('The assistant is not available to approve this action.')));
    socket.on('close', () => finish(deny('The approval request ended without a decision.')));
  });
}

async function handle(message) {
  const { id, method, params = {} } = message;
  if (id === undefined) return; // notifications (initialized, cancelled) need no reply
  if (method === 'initialize') return write({ id, result: { protocolVersion: typeof params.protocolVersion === 'string' ? params.protocolVersion : '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: 'brainkit-permissions', version: '0.1.0' } } });
  if (method === 'ping') return write({ id, result: {} });
  if (method === 'tools/list') return write({ id, result: { tools: [TOOL] } });
  if (method === 'tools/call' && params.name === TOOL.name) {
    const args = params.arguments ?? {};
    const decision = typeof args.tool_name === 'string' && args.input && typeof args.input === 'object' ? await ask(args) : deny('Malformed permission request.');
    return write({ id, result: { content: [{ type: 'text', text: JSON.stringify(decision) }] } });
  }
  write({ id, error: { code: -32601, message: `Unsupported method ${String(method).slice(0, 64)}` } });
}

let buffer = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
    if (!line.trim()) continue;
    let message;
    try { message = JSON.parse(line); } catch { write({ id: null, error: { code: -32700, message: 'Parse error' } }); continue; }
    handle(message).catch(error => write({ id: message.id ?? null, error: { code: -32603, message: String(error.message).slice(0, 256) } }));
  }
});
process.stdin.on('end', () => process.exit(0));
