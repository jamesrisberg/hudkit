import path from 'node:path';

/**
 * A runtime plugin for the tests: it answers each turn with its own text, prefixed by the
 * executable's name, and holds a turn whose text is "wait" until it is cancelled. It uses
 * only what the kit hands it.
 */
export default function create(kit, { executable, toolServers, options }) {
  class EchoRuntime extends kit.Runtime {
    static id = 'echo-agent';
    static displayName = 'Echo Agent';
    turns = 0; threads = 0; waiting = null;

    get capabilities() { return { approvals: false, folderScope: false, modelRouting: false, cancel: true }; }
    get supportsToolServers() { return true; }

    async start(_cwd, { saved }) {
      this.threads = saved.threads ?? 0;
      return { threadId: saved.threadId ?? this.newThread(), lastTurn: null };
    }
    newThread() { this.threads += 1; return `echo-thread-${this.threads}`; }
    async submit(text, { beforeSend }) {
      await beforeSend({});
      const turnId = `echo-turn-${++this.turns}`;
      this.emit('started', { turnId });
      if (text === 'wait') {
        this.waiting = turnId;
        this.emit('progress', { turnId, text: kit.claude.describe('Bash', { command: 'sleep 60', description: 'Waiting to be cancelled' }).reason });
        return { turnId };
      }
      const tools = kit.toolServers.allowedToolPatterns(toolServers).join(' ');
      const output = kit.bounded(`${path.basename(executable)}: ${text}${tools ? ` [${tools}]` : ''}`, 256);
      setImmediate(() => { this.emit('output', { turnId, text: output }); this.emit('completed', { turnId, output }); });
      return { turnId };
    }
    async cancel(turnId) {
      if (this.waiting !== turnId) return;
      this.waiting = null;
      setImmediate(() => this.emit('cancelled', { turnId, output: '' }));
    }
    async reset() { return { threadId: this.newThread() }; }
    snapshot() { return { ...super.snapshot(), sessionKey: `echo:${Object.keys(options).length}` }; }
    persistentState() { return { threads: this.threads }; }
  }
  return new EchoRuntime();
}
