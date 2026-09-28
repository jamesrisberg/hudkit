import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { CodexRpc } from '../runtimes/codex-rpc.mjs';

async function executable(t, code) {
  const directory = await mkdtemp(path.join(tmpdir(), 'brainkit-runtime-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const file = path.join(directory, 'fake-runtime');
  await writeFile(file, '#!/usr/bin/env node\n' + code, { mode: 0o700 });
  return file;
}
test('stdio JSONRPC handles split lines, correlated response, notifications and runtime error', async t => {
  const file = await executable(t, `process.stdin.on('data', chunk => {
    const m = JSON.parse(chunk.toString());
    if (m.method === 'bad') process.stdout.write(JSON.stringify({id:m.id,error:{message:'Denied'}})+'\\n');
    else { const line = JSON.stringify({id:m.id,result:{ok:true}})+'\\n'; process.stdout.write(line.slice(0,5)); process.stdout.write(line.slice(5)); }
  });`);
  const runtime = new CodexRpc({ executable: file, timeout: 1000 }); t.after(() => runtime.close());
  assert.deepEqual(await runtime.request('test', {}), { ok: true });
  await assert.rejects(runtime.request('bad', {}), /Denied/);
});
test('uncertain request timeout kills runtime instead of allowing unsafe retry', async t => {
  const file = await executable(t, `process.stdin.resume();`);
  const runtime = new CodexRpc({ executable: file, timeout: 50 }); t.after(() => runtime.close());
  await assert.rejects(runtime.request('turn/start', {}), /timed out/);
  assert.equal(runtime.dead, true);
  await assert.rejects(runtime.request('turn/start', {}), /unavailable/);
});
