import { lstat, readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { Runtime, bounded } from './Runtime.mjs';
import { describe } from './claude.mjs';
import { allowedToolPatterns, claudeMcpServers } from '../tool-servers.mjs';

/**
 * Runtime plugins: agent runtimes a host app installs beside the built-in ones (see README,
 * "Runtime plugins"). A plugin is a folder `<id>/` holding `runtime.json` and an adapter
 * module; the host finds the folders and passes each trusted one with `--runtime-plugin`.
 * The companion checks the trust rule again here, over the parent folder and the plugin's
 * whole folder, immediately before importing the adapter.
 */

/** A runtime id: what `--runtime`, the snapshot's `runtime` and the plugin's folder name hold. */
export const PLUGIN_ID = /^[a-z][a-z0-9-]{0,31}$/;
/** The `runtime.json` schema this companion reads. */
export const SCHEMA = 1;

/** What an adapter's factory receives: the companion helpers a runtime builds on. */
export const kit = Object.freeze({
  apiVersion: 1,
  Runtime,
  bounded,
  claude: Object.freeze({ describe }),
  toolServers: Object.freeze({ allowedToolPatterns, claudeMcpServers }),
});

const refusal = message => Object.assign(new Error(message), { refusal: true });

/** Why `id` cannot name a plugin, or null. */
export function invalidPluginId(id, reserved = []) {
  if (typeof id !== 'string' || !PLUGIN_ID.test(id)) return `"${bounded(id, 40)}" is not a valid runtime id (a lowercase letter, then up to 31 lowercase letters, digits or -)`;
  if (reserved.includes(id)) return `${id} is a built-in runtime`;
  return null;
}

/** The plugins named on the command line: `{ id: { directory, executable } }`. Throws on a malformed flag. */
export function pluginOptions(options, reserved = []) {
  const plugins = {};
  for (const value of options['--runtime-plugin'] ?? []) {
    const [id, directory] = splitPair(value);
    const invalid = invalidPluginId(id, reserved);
    if (invalid) throw new Error(`--runtime-plugin: ${invalid}`);
    if (!directory || !path.isAbsolute(directory)) throw new Error(`--runtime-plugin: ${id} needs an absolute folder (${id}=/path/to/${id})`);
    if (Object.hasOwn(plugins, id)) throw new Error(`--runtime-plugin: ${id} is given twice`);
    plugins[id] = { directory, executable: null };
  }
  for (const value of options['--runtime-executable'] ?? []) {
    const [id, executable] = splitPair(value);
    if (!Object.hasOwn(plugins, id)) throw new Error(`--runtime-executable: ${bounded(id, 40)} is not a --runtime-plugin`);
    if (!executable || !path.isAbsolute(executable)) throw new Error(`--runtime-executable: ${id} needs an absolute path`);
    if (plugins[id].executable !== null) throw new Error(`--runtime-executable: ${id} is given twice`);
    plugins[id].executable = executable;
  }
  return plugins;
}
function splitPair(value) {
  const index = value.indexOf('=');
  return index < 0 ? [value, ''] : [value.slice(0, index), value.slice(index + 1)];
}

/**
 * The trust rule, for one entry, checked without following links: not a symbolic link, owned
 * by this user (the effective user id) and writable by no one else. BrainKit's Swift side
 * (`RuntimePlugin.swift`) applies the same rule, in the same order, with the same reasons.
 */
async function trusted(file, label, kind) {
  let info;
  try { info = await lstat(file); }
  catch (error) { throw refusal(error.code === 'ENOENT' ? `${label} is missing` : `${label} cannot be read`); }
  if (info.isSymbolicLink()) throw refusal(`${label} is a symbolic link`);
  const fits = kind === 'directory' ? info.isDirectory() : kind === 'file' ? info.isFile() : info.isDirectory() || info.isFile();
  if (!fits) throw refusal(`${label} is not a ${{ directory: 'folder', file: 'regular file', entry: 'regular file or folder' }[kind]}`);
  if (info.uid !== process.geteuid()) throw refusal(`${label} is not owned by you`);
  if (info.mode & 0o022) throw refusal(`${label} is writable by other users`);
  return info;
}

/** At most this many entries in a plugin folder; a larger tree is refused rather than walked. */
export const MAX_ENTRIES = 4096;
/**
 * Every entry under the plugin folder, depth first in name order, checked against the trust
 * rule: a plugin's adapter may import any file beside it.
 */
async function trustedTree(folder) {
  let count = 0;
  const walk = async relative => {
    let names;
    try { names = (await readdir(path.join(folder, relative))).sort(); }
    catch { throw refusal(`"${relative}" in the plugin folder cannot be read`); }
    for (const name of names) {
      if (++count > MAX_ENTRIES) throw refusal(`The plugin folder has more than ${MAX_ENTRIES} entries`);
      const entry = relative ? `${relative}/${name}` : name;
      const info = await trusted(path.join(folder, entry), `"${bounded(entry, 256)}" in the plugin folder`, 'entry');
      if (info.isDirectory()) await walk(entry);
    }
  };
  await walk('');
}

const STRINGS = ['title', 'version', 'adapter', 'executable'];
const OPTIONAL_STRINGS = ['installCommand', 'loginCommand', 'loginTitle', 'note', 'summary', 'docsURL'];
const LISTS = ['searchPaths', 'requires'];
function isWebLink(text) {
  try { const url = new URL(text); return ['http:', 'https:'].includes(url.protocol) && url.hostname !== ''; } catch { return false; }
}
/** The known `runtime.json` fields, checked; unknown keys are dropped. */
function readManifest(value, id) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw refusal('runtime.json must hold an object');
  if (value.schema !== SCHEMA) throw refusal(`runtime.json has schema ${bounded(JSON.stringify(value.schema) ?? 'undefined', 16)}; this BrainKit reads schema ${SCHEMA}`);
  if (value.id !== id) throw refusal(`runtime.json's id "${bounded(value.id ?? 'undefined', 40)}" does not match its folder "${id}"`);
  const manifest = { schema: SCHEMA, id };
  for (const key of STRINGS) {
    if (typeof value[key] !== 'string' || !value[key].trim()) throw refusal(`runtime.json: "${key}" must be a non-empty string`);
    manifest[key] = value[key];
  }
  for (const key of LISTS) {
    if (value[key] === undefined) continue;
    if (!Array.isArray(value[key]) || !value[key].every(item => typeof item === 'string' && item)) throw refusal(`runtime.json: "${key}" must be a list of strings`);
    manifest[key] = [...value[key]];
  }
  for (const key of OPTIONAL_STRINGS) {
    if (value[key] === undefined) continue;
    if (typeof value[key] !== 'string') throw refusal(`runtime.json: "${key}" must be a string`);
    manifest[key] = value[key];
  }
  if (manifest.docsURL !== undefined && !isWebLink(manifest.docsURL)) throw refusal('runtime.json: "docsURL" must be an http or https URL');
  return Object.fromEntries(['schema', 'id', 'title', 'version', 'adapter', 'executable', ...LISTS, ...OPTIONAL_STRINGS]
    .filter(key => manifest[key] !== undefined).map(key => [key, manifest[key]]));
}

/**
 * Checks a plugin folder against the trust rule and reads its `runtime.json`. Resolves to
 * `{ id, directory, manifest, adapter }` (`adapter` the module's path); rejects with an error
 * whose `refusal` is true and whose message says why.
 */
export async function inspectPlugin(id, directory, { reserved = [] } = {}) {
  const invalid = invalidPluginId(id, reserved);
  if (invalid) throw refusal(invalid);
  if (!path.isAbsolute(directory)) throw refusal(`The plugin folder ${bounded(directory, 256)} is not an absolute path`);
  const folder = path.normalize(directory).replace(/\/+$/, '');
  if (path.basename(folder) !== id) throw refusal(`The plugin folder "${bounded(path.basename(folder), 64)}" is not named "${id}"`);
  const parent = path.dirname(folder);
  await trusted(parent, `The runtimes folder ${parent}`, 'directory');
  await trusted(folder, `The plugin folder ${folder}`, 'directory');
  const descriptor = path.join(folder, 'runtime.json');
  await trusted(descriptor, 'runtime.json', 'file');
  let text, value;
  try { text = await readFile(descriptor, 'utf8'); }
  catch { throw refusal('runtime.json cannot be read'); }
  try { value = JSON.parse(text); }
  catch { throw refusal('runtime.json is not valid JSON'); }
  const manifest = readManifest(value, id);
  const label = `The adapter "${bounded(manifest.adapter, 128)}"`;
  const adapter = path.resolve(folder, manifest.adapter);
  if (path.isAbsolute(manifest.adapter) || !adapter.startsWith(folder + path.sep)) throw refusal(`${label} is outside the plugin folder`);
  if (!adapter.endsWith('.mjs')) throw refusal(`${label} is not an .mjs module`);
  await trusted(adapter, label, 'file');
  await trustedTree(folder);
  return { id, directory: folder, manifest, adapter };
}

/** Stands in for a plugin that cannot run: offered like any runtime, its start says why. */
function unavailable(id, title, reason) {
  return new (class extends Runtime {
    static id = id;
    static displayName = title;
    async start() { throw new Error(`${id} cannot run: ${reason}`); }
  })();
}

/** How long a plugin's import and factory may take before the plugin counts as unavailable. */
export const LOAD_TIMEOUT_MS = 10000;

/**
 * The runtime of the plugin `id` (`{ directory, executable }` from the command line): the
 * adapter's factory called with the kit. A plugin that is refused, whose adapter fails or
 * takes longer than `timeoutMs` to load, is returned as a runtime whose start fails with the
 * reason, so the session reports it like any runtime that cannot start. The adapter is
 * imported once per companion process; the host restarts the companion when a plugin changes.
 */
export async function loadPlugin(id, { directory, executable }, { toolServers = [], reserved = [], timeoutMs = LOAD_TIMEOUT_MS } = {}) {
  let plugin;
  try { plugin = await inspectPlugin(id, directory, { reserved }); }
  catch (error) { return unavailable(id, id, error.message); }
  const title = plugin.manifest.title;
  const loading = (async () => {
    const module = await import(pathToFileURL(plugin.adapter).href);
    if (typeof module.default !== 'function') throw new Error('the adapter must default-export a factory function');
    return module.default(kit, { executable: executable ?? plugin.manifest.executable, toolServers, options: {} });
  })();
  let timer;
  const timeout = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`the adapter did not load within ${timeoutMs / 1000} s`)), timeoutMs); });
  let runtime;
  try { runtime = await Promise.race([loading, timeout]); }
  catch (error) {
    // A factory that finishes after the timeout made a runtime nobody will use.
    loading.then(late => closeQuietly(late), () => {});
    return unavailable(id, title, bounded(error.message, 2048));
  } finally { clearTimeout(timer); }
  if (!(runtime instanceof Runtime)) {
    closeQuietly(runtime);
    return unavailable(id, title, 'the adapter must return a kit.Runtime subclass instance');
  }
  if (runtime.id !== id) {
    closeQuietly(runtime);
    return unavailable(id, title, `the adapter made a runtime with id "${bounded(runtime.id, 40)}", not "${id}"`);
  }
  return runtime;
}
function closeQuietly(value) {
  try { if (value && typeof value.close === 'function') value.close(); } catch {}
}
