// Opt-in: runs real model turns, and approves ONLY an exact toy command in fresh temp folders.
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, realpath, readFile, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { CodexRuntime } from './runtimes/codex.mjs';
import { Session } from './session.mjs';
import { saveState } from './server.mjs';

const root = await realpath(await mkdtemp(path.join(tmpdir(), 'brainkit-permission-acceptance-')));
assert.match(root, /^[a-zA-Z0-9_./-]+$/, 'Temporary path must be safe for exact literal shell commands');
const cwd = path.join(root, 'workspace'), outside = path.join(root, 'outside'), state = path.join(root, 'state');
await Promise.all([cwd, outside, state].map(folder => mkdir(folder)));
const runtime = new CodexRuntime({ executable: process.env.BRAINKIT_CODEX ?? 'codex' });
const session = new Session({ runtime, cwd, save: value => saveState(state, value) });
let unexpected = null;
runtime.on('message', message => {
  if (message.id !== undefined && (message.method !== 'item/commandExecution/requestApproval' || message.params?.grantRoot != null)) unexpected = `Unexpected request: ${message.method}`;
});
async function exists(file) { try { await access(file); return true; } catch { return false; } }
async function turn(name, file, decision = null) {
  // No untrusted shell content: paths come exclusively from our mkdtemp and literal suffixes.
  const command = `printf 'permission-test' > '${file}'`;
  unexpected = null;
  const instruction = `Permission acceptance test. Run exactly this shell command once: ${command}\nOnly run this command; do not inspect files, invoke other tools, or change its text. ${decision ? 'Use sandbox_permissions require_escalated for this exact command so I can approve or deny this specific action. Do not request persistent or permission-profile grants. If denied, stop immediately without retrying or using another tool.' : 'Use normal sandbox execution; do not request escalation.'} Briefly report the result.`;
  await session.submit(instruction, randomUUID());
  let approved = 0;
  const deadline = Date.now() + 180000;
  for (;;) {
    if (unexpected) throw new Error(unexpected);
    const snapshot = session.snapshot();
    for (const approval of snapshot.approvals) {
      console.log(JSON.stringify({ phase: 'approval', name, command: approval.command }));
      assert.ok(decision, 'Unexpected approval in preapproved mode');
      assert.equal(approval.kind, 'command');
      assert.ok([command, `/bin/zsh -lc \"${command}\"`, `/bin/bash -lc \"${command}\"`].includes(approval.command), 'Refusing approval: command differs from exact toy action');
      assert.equal(approved++, 0, 'Refusing duplicate approval');
      session.approve(approval.id, decision);
    }
    if (!['running', 'approval'].includes(snapshot.status)) {
      assert.equal(snapshot.status, 'idle', snapshot.error || snapshot.progress);
      assert.equal(approved, decision ? 1 : 0, 'Expected exact-action approval was not requested');
      break;
    }
    if (Date.now() > deadline) throw new Error('Acceptance timed out');
    await new Promise(resolve => setTimeout(resolve, 250));
  }
  if (decision === 'decline') assert.equal(await exists(file), false, 'Denied file was written');
  else assert.equal(await readFile(file, 'utf8'), 'permission-test');
  console.log(JSON.stringify({ phase: name, verified: true }));
}
try {
  await session.initialize();
  console.log(JSON.stringify({ phase: 'ready', root, threadId: session.snapshot().threadId }));
  await session.setPermissions({ mode: 'fullAccess', approvedFolders: [cwd] });
  await turn('full-access', path.join(outside, 'full.txt'));
  await session.setPermissions({ mode: 'approvedFolders', approvedFolders: [cwd] });
  await turn('approved-folder', path.join(cwd, 'approved.txt'));
  await turn('outside-denied', path.join(outside, 'denied.txt'), 'decline');
  await turn('outside-allowed-once', path.join(outside, 'allowed.txt'), 'accept');
  await turn('outside-asks-again', path.join(outside, 'again.txt'), 'decline');
  console.log(JSON.stringify({ result: 'PASS', root }));
} finally { runtime.close(); }
