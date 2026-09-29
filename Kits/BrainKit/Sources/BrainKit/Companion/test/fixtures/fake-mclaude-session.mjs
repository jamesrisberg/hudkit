// A fake mechaclaude session: the hub socket and sidecar an instrumented Claude Code
// session publishes (PROTOCOL.md "Transport"), speaking the frames and control verbs the
// mclaude runtime uses. Every connected client sees every frame, so a test can drive the
// session from a second client the way MechaHUD's dashboard does.
//   submit "hello"        streams "Hello there." and ends the turn
//   submit "approve ..."  opens a Bash permission dialog with its select overlay
//   submit "slow ..."     streams "Once upon" and waits for interrupt
//   submit "fail ..."     reports an API error and ends without an answer
//   submit "/clear"       switches to a new session id
// FAKE_MCLAUDE_GATED=1 starts behind the folder-trust overlay.
import { randomUUID } from 'node:crypto';
import { mkdirSync, unlinkSync, writeFileSync } from 'node:fs';
import net from 'node:net';
import path from 'node:path';

const config = JSON.parse(process.argv[2]);
const directory = process.env.MCLAUDE_STATE_DIR;
mkdirSync(directory, { recursive: true });
const sock = path.join(directory, `cc-${process.pid}.sock`);
const metaPath = path.join(directory, `cc-${process.pid}.meta.json`);
let sessionId = randomUUID();
const clients = new Set();
let gated = process.env.FAKE_MCLAUDE_GATED === '1';
let busy = false; let dialogs = [];
let overlay = gated ? { type: 'overlay', subtype: 'select', options: [{ value: 'confirm', label: 'Yes, I trust this folder' }, { value: 'cancel', label: 'No, exit' }], focusedValue: 'confirm', cancelable: true } : null; let pendingAnswer = null; let running = null; let msg = 0; let dialogSeq = 0;

const write = (client, frame) => { if (!client.destroyed) client.write(JSON.stringify({ pid: process.pid, sessionId, t: Date.now(), ...frame }) + '\n'); };
const broadcast = frame => { for (const client of clients) write(client, frame); };
const affordances = () => ({ busy, canSubmit: !gated && !dialogs.length, canInterrupt: busy, canChoose: Boolean(overlay), canAnswer: dialogs.length > 0, permissionMode: 'acceptEdits' });
const setBusy = value => {
  busy = value;
  broadcast({ type: 'turn', view: 'turn', data: { loading: value, streaming: false } });
  broadcast({ type: 'affordances', affordances: affordances() });
};
const record = (type, fields) => broadcast({ type: 'message', source: 'transcript', message: { type, uuid: randomUUID(), timestamp: new Date().toISOString(), isSidechain: false, ...fields } });
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
function stream(text, querySource = 'repl_main_thread') {
  const id = `msg_${++msg}`;
  broadcast({ type: 'stream_event', channel: 'lifecycle', msgSeq: msg, msgId: id, querySource, event: { kind: 'message_start' } });
  for (const piece of text.match(/.{1,6}/g) ?? []) broadcast({ type: 'stream_event', channel: 'text', msgSeq: msg, querySource, event: { kind: 'content_block_delta', index: 0, delta: 'text_delta', text: piece } });
  return id;
}
function answer(text) {
  const id = stream(text);
  record('assistant', { message: { id, role: 'assistant', content: [{ type: 'text', text }], stop_reason: 'end_turn' } });
  record('system', { subtype: 'turn_duration', durationMs: 5 });
  setBusy(false);
  running = null;
}

let transcript = null;
async function run(text) {
  running = { text };
  // Claude Code creates the transcript with the first turn.
  if (!transcript) { transcript = path.join(directory, `${sessionId}.jsonl`); writeFileSync(transcript, ''); broadcast({ type: 'transcript_path', path: transcript }); }
  record('user', { message: { role: 'user', content: text } });
  setBusy(true);
  await delay(20);
  if (text === '/clear') {
    sessionId = randomUUID(); transcript = null;
    broadcast({ type: 'sid', sessionId });
    setBusy(false); running = null;
    return;
  }
  if (text.startsWith('approve')) {
    stream('Checking.', 'generate_session_title');
    record('assistant', { message: { id: `msg_${++msg}`, role: 'assistant', content: [{ type: 'tool_use', id: 'toolu_1', name: 'Bash', input: { command: 'rm -rf /tmp/demo', description: 'Delete the demo folder' } }], stop_reason: 'tool_use' } });
    broadcast({ type: 'tool_state', id: 'toolu_1', state: 'running', name: 'Bash' });
    const id = `dialog-${++dialogSeq}`;
    dialogs = [{ id, kind: 'permission_bash', payload: { requestId: 'toolu_1', toolName: 'Bash', input: { command: 'rm -rf /tmp/demo', description: 'Delete the demo folder' } } }];
    overlay = { type: 'overlay', subtype: 'select', options: [{ value: 'yes', label: 'Yes' }, { value: 'yes-dont-ask-again', label: "Yes, and don't ask again for rm commands" }, { value: 'no', label: 'No, and tell Claude what to do differently' }], focusedValue: 'yes', cancelable: true };
    broadcast({ type: 'dialog', open: dialogs }); broadcast(overlay);
    broadcast({ type: 'affordances', affordances: affordances() });
    const decision = await new Promise(resolve => { pendingAnswer = resolve; });
    dialogs = []; overlay = null; pendingAnswer = null;
    broadcast({ type: 'dialog_answer', id, result: { behavior: decision } });
    broadcast({ type: 'dialog', open: [] }); broadcast({ type: 'overlay', subtype: 'select', closed: true });
    answer(decision === 'allow' ? 'Allowed rm -rf /tmp/demo' : 'Denied.');
    return;
  }
  if (text.startsWith('slow')) {
    const id = stream('Once upon');
    running.abort = () => {
      broadcast({ type: 'turn_pulse', phase: 'aborted', reason: 'user-cancel' });
      record('assistant', { message: { id, role: 'assistant', content: [{ type: 'text', text: 'Once upon' }], stop_reason: null } });
      setBusy(false); running = null;
    };
    return;
  }
  if (text.startsWith('fail')) {
    broadcast({ type: 'error', subtype: 'api_error', level: 'error', error: { message: '529 overloaded' } });
    setBusy(false); running = null;
    return;
  }
  stream('{"title":"Greeting"}', 'generate_session_title');
  answer('Hello there.');
}

function control(client, frame) {
  const ack = (status, detail = null) => { if (frame.cid) write(client, { type: 'ack', cid: frame.cid, action: frame.action, status, detail, nonce: null }); };
  switch (frame.action) {
    case 'affordances': write(client, { type: 'affordances', affordances: affordances() }); return ack('dispatched');
    case 'submit':
      if (gated) return ack('noop', 'input is not mounted');
      if (running) return ack('applied');
      ack('applied'); run(String(frame.text)); return;
    case 'interrupt':
      if (!running?.abort) return ack('noop', 'no active query');
      ack('applied'); running.abort(); return;
    case 'choose': {
      if (!overlay) return ack('noop', 'no select');
      const option = overlay.options[frame.index];
      if (gated) { gated = false; overlay = null; broadcast({ type: 'overlay', subtype: 'select', closed: true }); broadcast({ type: 'affordances', affordances: affordances() }); return ack('applied'); }
      ack('applied');
      pendingAnswer?.(option?.value === 'yes' ? 'allow' : 'deny');
      return;
    }
    case 'answer':
      if (!dialogs.length) return ack('noop', 'no dialog');
      ack('applied');
      pendingAnswer?.(frame.result?.behavior === 'allow' ? 'allow' : 'deny');
      return;
    default: return ack('unknown');
  }
}

const server = net.createServer(client => {
  clients.add(client);
  client.on('close', () => clients.delete(client));
  client.on('error', () => {});
  write(client, { type: 'snapshot', state: {} });
  if (overlay) write(client, overlay);
  if (transcript) write(client, { type: 'transcript_path', snapshot: true, path: transcript });
  write(client, { type: 'turn', view: 'turn', snapshot: true, data: { loading: busy } });
  write(client, { type: 'dialog', open: dialogs });
  let buffer = '';
  client.setEncoding('utf8');
  client.on('data', chunk => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
      let frame; try { frame = JSON.parse(line); } catch { continue; }
      if (frame.type === 'control') control(client, frame);
    }
  });
});
const cleanup = () => { try { unlinkSync(sock); } catch {} try { unlinkSync(metaPath); } catch {} };
process.on('SIGTERM', () => { cleanup(); process.exit(0); });
process.on('SIGINT', () => { cleanup(); process.exit(0); });
server.listen(sock, () => {
  writeFileSync(metaPath, JSON.stringify({ pid: process.pid, sessionId, cwd: config.cwd, argv: config.args, startedAt: Date.now(), version: '2.1.284', spawnTag: config.tag, sock }));
});
// Never outlive a test run by long.
setTimeout(() => { cleanup(); process.exit(0); }, 60000).unref?.();
