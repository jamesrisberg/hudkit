// Real non-action turns in an isolated thread; never touches the live session.
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { CodexRuntime } from './runtimes/codex.mjs';
import { Session } from './session.mjs';
const cwd = await mkdtemp(path.join(tmpdir(), 'brainkit-routing-'));
const runtime = new CodexRuntime({executable:process.env.BRAINKIT_CODEX ?? 'codex'});
const session = new Session({runtime,cwd});
try {
  await session.initialize();
  const thread = session.snapshot().threadId;
  for (const [requestId,text,tier] of [
    ['routing-fast','What is two plus two? Reply in one short sentence; do not use tools.','fast'],
    ['routing-deep','Compare the number in your previous answer with five. Which is larger? Reply in one short sentence; do not use tools.','deep'],
  ]) {
    await session.submit(text,requestId);
    const deadline = Date.now() + 120000;
    while (session.snapshot().status === 'running' && Date.now() < deadline) await delay(100);
    const snapshot = session.snapshot();
    assert.equal(snapshot.status,'idle', snapshot.error ?? 'Turn did not complete');
    assert.equal(snapshot.threadId,thread);
    assert.equal(snapshot.route.tier,tier);
    assert.ok(snapshot.output.trim());
    console.log(JSON.stringify({route:snapshot.route,timing:snapshot.timing,output:snapshot.output}));
  }
} finally { runtime.close(); await rm(cwd,{recursive:true,force:true}); }
