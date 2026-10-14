import { CodexRuntime } from './codex.mjs';
import { HermesRuntime } from './hermes.mjs';
import { ClaudeRuntime } from './claude.mjs';
import { loadPlugin } from './plugins.mjs';

/** Built-in runtimes. Adding a brain means adding its adapter here (see README); others are plugins. */
export const RUNTIMES = { codex: CodexRuntime, hermes: HermesRuntime, claude: ClaudeRuntime };
export const RUNTIME_IDS = Object.keys(RUNTIMES);

/**
 * Build a runtime from companion options. Only options for the chosen runtime are
 * read; an unknown name throws a 400 so a bad switch request cannot start work.
 * Every runtime also receives `toolServers` (validated, see tool-servers.mjs); Hermes ignores them.
 *   codex:  { codex: '/path/to/codex' }
 *   hermes: { runtimeUrl, runtimeToken }
 *   claude: { claude: '/path/to/claude' }
 *   a plugin: { plugins: { <id>: { directory, executable } } } (see plugins.mjs)
 */
export async function createRuntime(name, options = {}) {
  const plugins = options.plugins ?? {};
  const toolServers = options.toolServers ?? [];
  if (!Object.hasOwn(RUNTIMES, name)) {
    if (Object.hasOwn(plugins, name)) return loadPlugin(name, plugins[name], { toolServers, reserved: RUNTIME_IDS });
    throw Object.assign(new Error(`Unknown runtime "${String(name).slice(0, 32)}". Choose one of: ${[...RUNTIME_IDS, ...Object.keys(plugins)].join(', ')}`), { status: 400 });
  }
  if (name === 'codex') return new CodexRuntime({ executable: options.codex ?? 'codex', toolServers });
  if (name === 'hermes') return new HermesRuntime({ url: options.runtimeUrl, token: options.runtimeToken });
  return new ClaudeRuntime({ executable: options.claude ?? 'claude', toolServers });
}
