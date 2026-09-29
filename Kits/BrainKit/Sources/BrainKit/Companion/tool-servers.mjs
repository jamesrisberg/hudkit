// Tool servers: stdio MCP servers the host gives its brain (`--tool-servers <file>`), and how
// each runtime is told about them. The file is a JSON array written by the Swift side:
//   [{ "name": "machud", "command": "/path/machud-mcp", "arguments": [], "environment": {},
//      "requireApproval": false }]

/** Server names become config keys (`mcp_servers.<name>`) and tool prefixes (`mcp__<name>__`). */
export const TOOL_SERVER_NAME = /^[A-Za-z0-9_-]{1,64}$/;
// Names the companion itself uses for Claude Code's permission bridge.
const RESERVED_NAMES = new Set(['brainkit_permissions']);
const MAX_SERVERS = 16;

function invalid(message) { return new Error(`Invalid tool servers: ${message}`); }
function isPlainObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function oneLine(value, limit) { return typeof value === 'string' && value.length > 0 && value.length <= limit && !/[\0\r\n]/.test(value); }

/** Validates the decoded `--tool-servers` file; throws on anything it cannot pass on exactly. */
export function parseToolServers(value) {
  if (!Array.isArray(value)) throw invalid('expected a JSON array');
  if (value.length > MAX_SERVERS) throw invalid(`at most ${MAX_SERVERS} servers`);
  const names = new Set();
  return value.map((server, index) => {
    const where = `server ${index + 1}`;
    if (!isPlainObject(server)) throw invalid(`${where} is not an object`);
    const extra = Object.keys(server).filter(key => !['name', 'command', 'arguments', 'environment', 'requireApproval'].includes(key));
    if (extra.length) throw invalid(`${where} has unknown keys: ${extra.join(', ')}`);
    const { name, command, arguments: args = [], environment = {}, requireApproval = false } = server;
    if (typeof name !== 'string' || !TOOL_SERVER_NAME.test(name)) throw invalid(`${where} needs a name of letters, digits, _ or - (at most 64)`);
    if (RESERVED_NAMES.has(name)) throw invalid(`the name ${name} is reserved`);
    if (names.has(name)) throw invalid(`the name ${name} is used twice`);
    names.add(name);
    if (!oneLine(command, 4096)) throw invalid(`${name} needs a command`);
    if (!Array.isArray(args) || args.length > 64 || !args.every(arg => typeof arg === 'string' && arg.length <= 4096 && !arg.includes('\0'))) throw invalid(`${name} arguments must be strings`);
    if (!isPlainObject(environment) || Object.keys(environment).length > 64
      || !Object.entries(environment).every(([key, entry]) => /^[A-Za-z_][A-Za-z0-9_]{0,127}$/.test(key) && typeof entry === 'string' && entry.length <= 4096 && !entry.includes('\0')))
      throw invalid(`${name} environment must map variable names to strings`);
    if (typeof requireApproval !== 'boolean') throw invalid(`${name} requireApproval must be true or false`);
    return { name, command, arguments: [...args], environment: { ...environment }, requireApproval };
  });
}

/** A TOML basic string. JSON's escapes are valid TOML; DEL is the one control JSON leaves raw. */
export function tomlString(value) { return JSON.stringify(String(value)).replace(/\u007f/g, '\\u007F'); }

/**
 * `codex app-server` config overrides, one `-c key=value` pair per setting (values are TOML).
 * Codex asks before an MCP tool call according to `default_tools_approval_mode`: "approve"
 * never asks, "prompt" always asks (as an `mcpServer/elicitation/request` the codex runtime
 * turns into an approval).
 */
export function codexConfigArgs(servers) {
  const args = [];
  for (const server of servers) {
    const key = `mcp_servers.${server.name}`;
    args.push('-c', `${key}.command=${tomlString(server.command)}`);
    args.push('-c', `${key}.args=[${server.arguments.map(tomlString).join(', ')}]`);
    const env = Object.entries(server.environment);
    if (env.length) args.push('-c', `${key}.env={ ${env.map(([name, value]) => `${tomlString(name)} = ${tomlString(value)}`).join(', ')} }`);
    args.push('-c', `${key}.default_tools_approval_mode=${tomlString(server.requireApproval ? 'prompt' : 'approve')}`);
  }
  return args;
}

/** Claude Code's `mcpServers` entries (`--mcp-config`). */
export function claudeMcpServers(servers) {
  return Object.fromEntries(servers.map(server => [server.name,
    { type: 'stdio', command: server.command, args: server.arguments, env: server.environment }]));
}

/** `--allowedTools` patterns for the servers that run without asking. */
export function allowedToolPatterns(servers) {
  return servers.filter(server => !server.requireApproval).map(server => `mcp__${server.name}__*`);
}

/** The instructions a runtime receives: the voice instructions, then the host's context. */
export function withHostContext(instructions, hostContext) {
  const context = String(hostContext ?? '').trim();
  return context ? `${instructions}\n\n${context}` : instructions;
}
