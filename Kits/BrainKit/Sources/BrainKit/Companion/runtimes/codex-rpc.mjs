import { spawn } from 'node:child_process';
import { EventEmitter } from 'node:events';

/** A private stdio connection; the app-server never opens a network listener. */
export class CodexRpc extends EventEmitter {
  /** `configArgs` are `-c key=value` overrides for `codex app-server` (tool servers). */
  constructor({ executable = 'codex', cwd, timeout = 30000, configArgs = [] } = {}) {
    super();
    this.pending = new Map(); this.nextID = 1; this.timeout = timeout;
    this.child = spawn(executable, ['app-server', ...configArgs], { cwd, stdio: ['pipe', 'pipe', 'pipe'] });
    let buffer = '';
    this.child.stdout.setEncoding('utf8');
    this.child.stdout.on('data', chunk => {
      buffer += chunk;
      if (buffer.length > 8 * 1024 * 1024) { this.fail(new Error('Runtime message exceeded size limit')); this.close(); return; }
      let newline;
      while ((newline = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
        if (!line.trim()) continue;
        try { this.receive(JSON.parse(line)); }
        catch { this.fail(new Error('Invalid runtime protocol message')); this.close(); return; }
      }
    });
    // Drain diagnostics without exposing potentially sensitive runtime output over HTTP.
    this.child.stderr.resume();
    this.child.stdin.on('error', error => this.fail(error));
    this.child.on('error', error => this.fail(error));
    this.child.on('exit', () => this.fail(new Error('Codex runtime disconnected. Restart the companion to resume.')));
  }
  receive(message) {
    if (message.method) { this.emit('message', message); return; }
    const pending = this.pending.get(message.id);
    if (!pending) return;
    this.pending.delete(message.id); clearTimeout(pending.timer);
    if (message.error) pending.reject(new Error(message.error.message || 'Runtime request failed'));
    else pending.resolve(message.result);
  }
  send(message) {
    if (this.dead || !this.child.stdin.writable) throw new Error('Codex runtime is unavailable');
    this.child.stdin.write(JSON.stringify(message) + '\n');
  }
  request(method, params) {
    const id = this.nextID++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        // A timed-out mutation may have executed: never keep a runtime whose state is uncertain.
        this.fail(new Error(`Codex ${method} timed out; restart the companion to reconcile the session`));
        this.close(); reject(new Error(`Codex ${method} timed out`));
      }, this.timeout);
      this.pending.set(id, { resolve, reject, timer });
      try { this.send({ id, method, params }); }
      catch (error) { clearTimeout(timer); this.pending.delete(id); reject(error); }
    });
  }
  reply(id, result) { this.send({ id, result }); }
  reject(id) { this.send({ id, error: { code: -32601, message: 'This client does not support this request. No permission was granted.' } }); }
  fail(error) {
    if (this.dead) return;
    this.dead = true;
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.pending.clear(); this.emit('disconnect', error);
  }
  close() {
    this.child.stdin.end(); this.child.kill('SIGTERM');
    const timer = setTimeout(() => this.child.kill('SIGKILL'), 2000); timer.unref();
  }
}
