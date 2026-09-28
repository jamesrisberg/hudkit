import test from 'node:test';
import assert from 'node:assert/strict';
import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArguments } from '../server.mjs';
import { Session } from '../session.mjs';
import { Runtime } from '../runtimes/Runtime.mjs';
import { voiceInstructions } from '../voice-instructions.mjs';

const ROOT = fileURLToPath(new URL('..', import.meta.url));

test('voice instructions name no assistant unless the host gives one', () => {
  assert.match(voiceInstructions(), /^You are a capable personal voice assistant on the user's Mac\./);
  assert.match(voiceInstructions('Jarvis'), /^You are Jarvis, a capable personal voice assistant on the user's Mac\./);
  assert.equal(voiceInstructions('  '), voiceInstructions());
});

test('--assistant-name is a single short line', () => {
  assert.equal(parseArguments(['--cwd', '/w', '--assistant-name', 'Jarvis'])['--assistant-name'], 'Jarvis');
  assert.throws(() => parseArguments(['--cwd', '/w', '--assistant-name', 'Two\nlines']), /--assistant-name/);
  assert.throws(() => parseArguments(['--cwd', '/w', '--assistant-name', 'x'.repeat(65)]), /--assistant-name/);
});

test('the session hands its instructions to the runtime', async () => {
  class Recording extends Runtime {
    static id = 'recording';
    async start(_cwd, options) { this.options = options; return { threadId: 't', lastTurn: null }; }
  }
  const named = new Recording();
  await new Session({ runtime: named, cwd: '/w', instructions: voiceInstructions('Jarvis') }).initialize();
  assert.match(named.options.instructions, /^You are Jarvis,/);
  const plain = new Recording();
  await new Session({ runtime: plain, cwd: '/w' }).initialize();
  assert.equal(plain.options.instructions, voiceInstructions());
});

test('no host app name appears in the service, its protocol names or its environment', async () => {
  const host = new RegExp(['archi', 'bald'].join(''), 'i');
  const files = [];
  async function walk(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) await walk(file);
      else files.push(file);
    }
  }
  await walk(ROOT);
  for (const file of files) assert.doesNotMatch(await readFile(file, 'utf8'), host, path.relative(ROOT, file));
});
