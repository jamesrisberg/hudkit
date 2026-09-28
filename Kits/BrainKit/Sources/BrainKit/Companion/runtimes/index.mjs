import { CodexRuntime } from './codex.mjs';
import { HermesRuntime } from './hermes.mjs';
import { ClaudeRuntime } from './claude.mjs';

/** Registered runtimes. Adding a brain means adding its adapter here (see README). */
export const RUNTIMES = { codex: CodexRuntime, hermes: HermesRuntime, claude: ClaudeRuntime };
export const RUNTIME_IDS = Object.keys(RUNTIMES);

/**
 * Build a runtime from companion options. Only options for the chosen runtime are
 * read; a missing requirement throws a 400 so a bad switch request cannot start work.
 *   codex:  { codex: '/path/to/codex' }
 *   hermes: { runtimeUrl, runtimeToken }
 *   claude: { claude: '/path/to/claude', stateDirectory }
 */
export function createRuntime(name, options = {}) {
  const Adapter = RUNTIMES[name];
  if (!Adapter) throw Object.assign(new Error(`Unknown runtime "${String(name).slice(0, 32)}". Choose one of: ${RUNTIME_IDS.join(', ')}`), { status: 400 });
  if (name === 'codex') return new CodexRuntime({ executable: options.codex ?? 'codex' });
  if (name === 'hermes') return new HermesRuntime({ url: options.runtimeUrl, token: options.runtimeToken });
  return new ClaudeRuntime({ executable: options.claude ?? 'claude' });
}
