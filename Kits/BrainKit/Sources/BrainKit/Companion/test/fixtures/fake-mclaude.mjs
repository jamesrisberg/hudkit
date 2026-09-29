#!/usr/bin/env node
// Stand-in for mechaclaude's `mclaude` wrapper in its `--mc-detach` mode: starts a fake
// session process (fake-mclaude-session.mjs) detached, like the wrapper's tmux pane, and
// prints the wrapper's handle line. Every call is appended to FAKE_MCLAUDE_LOG.
import { spawn } from 'node:child_process';
import { appendFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
if (process.env.FAKE_MCLAUDE_LOG) {
  appendFileSync(process.env.FAKE_MCLAUDE_LOG, JSON.stringify({ args, claudecode: process.env.CLAUDECODE ?? null, childSession: process.env.CLAUDE_CODE_CHILD_SESSION ?? null }) + '\n');
}
if (process.env.FAKE_MCLAUDE_FAIL) {
  process.stderr.write(`mclaude: ${process.env.FAKE_MCLAUDE_FAIL}\n`);
  process.exit(1);
}
const value = flag => { const index = args.indexOf(flag); return index >= 0 ? args[index + 1] : null; };
if (!args.includes('--mc-detach')) { process.stderr.write('mclaude: this fake only detaches\n'); process.exit(2); }
const name = value('--mc-name'); const tag = value('--mc-tag'); const cwd = value('--mc-cwd');
const passthrough = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--mc-detach') continue;
  if (['--mc-name', '--mc-tag', '--mc-cwd'].includes(args[i])) { i++; continue; }
  passthrough.push(args[i]);
}
const session = fileURLToPath(new URL('./fake-mclaude-session.mjs', import.meta.url));
const child = spawn(process.execPath, [session, JSON.stringify({ tag, cwd, args: passthrough })], { detached: true, stdio: 'ignore', env: process.env });
child.unref();
process.stdout.write(`name=${name} pid=${child.pid} ver=2.1.284 tag=${tag}\n`);
