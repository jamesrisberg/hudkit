// Explicit real-model acceptance test. Uses only its own newly created temporary workspace.
import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { randomBytes, randomUUID } from 'node:crypto';
import { CodexRuntime } from './runtimes/codex.mjs';
import { Session } from './session.mjs';
import { createServer, saveState } from './server.mjs';

const workspace = await mkdtemp(path.join(tmpdir(), 'brainkit-acceptance-workspace-'));
const stateDirectory = await mkdtemp(path.join(tmpdir(), 'brainkit-acceptance-state-'));
const token = randomBytes(32).toString('hex');
const runtime = new CodexRuntime({ executable: process.env.BRAINKIT_CODEX ?? 'codex' });
const session = new Session({ runtime, cwd: workspace, save: state => saveState(stateDirectory, state) });
const server = createServer({ session, token });
async function request(route, body) {
  const response = await fetch(`http://127.0.0.1:${server.address().port}${route}`, { method: body ? 'POST' : 'GET', headers: { Authorization: `Bearer ${token}`, ...(body ? { 'Content-Type': 'application/json' } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}) });
  const value = await response.json();
  if (!response.ok) throw new Error(value.error);
  return value;
}
async function turn(text) {
  let snapshot = await request('/v1/turn', { text, requestId: randomUUID() });
  const deadline = Date.now() + 180000;
  while (['running', 'approval'].includes(snapshot.status)) {
    if (snapshot.approvals.length) throw new Error('Acceptance unexpectedly requested permission; no approval was granted');
    if (Date.now() > deadline) throw new Error('Acceptance timed out');
    await new Promise(resolve => setTimeout(resolve, 500));
    snapshot = await request('/v1/session');
  }
  if (snapshot.status !== 'idle') throw new Error(snapshot.error || `Turn ${snapshot.status}`);
  return snapshot;
}
try {
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  await session.initialize();
  console.log(JSON.stringify({ phase: 'ready', workspace, stateDirectory, threadId: session.snapshot().threadId }));
  const first = await turn('Acceptance test: create acceptance-note.txt in the current workspace with exactly this single line: BrainKit acceptance: first version\nOnly touch this test file. Do not inspect other directories or run setup. Use your file editing tool and briefly confirm.');
  const firstContent = await readFile(path.join(workspace, 'acceptance-note.txt'), 'utf8');
  if (firstContent.trim() !== 'BrainKit acceptance: first version') throw new Error('First note content mismatch');
  console.log(JSON.stringify({ phase: 'created', threadId: first.threadId, turnId: first.turnId, output: first.output, fileVerified: true }));
  const second = await turn('Revise the same note we just created. Replace its content with exactly this single line: BrainKit acceptance: revised version\nOnly touch that same test file and briefly confirm.');
  const secondContent = await readFile(path.join(workspace, 'acceptance-note.txt'), 'utf8');
  if (second.threadId !== first.threadId || second.turnId === first.turnId) throw new Error('Conversation continuity mismatch');
  if (secondContent.trim() !== 'BrainKit acceptance: revised version') throw new Error('Revised note content mismatch');
  console.log(JSON.stringify({ phase: 'revised', threadId: second.threadId, turnId: second.turnId, output: second.output, fileVerified: true, result: 'PASS' }));
} finally { runtime.close(); server.closeAllConnections(); server.close(); }
