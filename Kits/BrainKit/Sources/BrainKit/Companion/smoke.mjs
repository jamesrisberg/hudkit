// Establish a real protocol connection and read account state. Never starts a model turn.
import { CodexRpc } from './runtimes/codex-rpc.mjs';
const runtime = new CodexRpc({ executable: process.env.BRAINKIT_CODEX ?? 'codex', cwd: process.cwd() });
try {
  const initialized = await runtime.request('initialize', { clientInfo: { name: 'brainkit_smoke', version: '0.1.0' }, capabilities: { experimentalApi: false } });
  runtime.send({ method: 'initialized', params: {} });
  const account = await runtime.request('account/read', {});
  console.log(JSON.stringify({ protocol: 'ok', userAgent: initialized.userAgent, signedIn: Boolean(account.account), requiresOpenaiAuth: account.requiresOpenaiAuth }));
} finally { runtime.close(); }
