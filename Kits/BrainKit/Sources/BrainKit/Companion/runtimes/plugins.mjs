import { lstat, readFile, realpath } from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { Runtime, bounded } from './Runtime.mjs';
import { describe } from './claude.mjs';
import { allowedToolPatterns, claudeMcpServers } from '../tool-servers.mjs';

/**
 * Runtime plugins: agent runtimes a host app installs beside the built-in ones (see README,
 * "Runtime plugins"). A plugin is a folder `<id>/` holding `runtime.json` and an adapter
 * module; the host finds the folders and passes each trusted one with `--runtime-plugin`.
 * The companion checks the trust rule again here, immediately before importing the adapter.
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
 * The trust rule, for the folder or a file in it, checked without following links: not a
 * symbolic link, owned by this user (the effective user id) and writable by no one else.
 * BrainKit's Swift side (`RuntimePlugin.swift`) applies the same rule with the same reasons.
 */
async function trusted(file, label, kind) {
  let info;
  try { info = await lstat(file); }
  catch (error) { throw refusal(error.code === 'ENOENT' ? `${label} is missing` : `${label} cannot be read (${error.code ?? error.message})`); }
  if (info.isSymbolicLink()) throw refusal(`${label} is a symbolic link`);
  if (kind === 'directory' ? !info.isDirectory() : !info.isFile()) throw refusal(`${label} is not a ${kind === 'directory' ? 'folder' : 'regular file'}`);
  if (info.uid !== process.geteuid()) throw refusal(`${label} is not owned by you`);
  if (info.mode & 0o022) throw refusal(`${label} is writable by other users`);
  return info;
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
 * `{ id, directory, manifest, adapter, version }` (`adapter` the module's path,
 * `version` its modification time and size); rejects with an
 * error whose `refusal` is true and whose message says why.
 */
export async function inspectPlugin(id, directory, { reserved = [] } = {}) {
  const invalid = invalidPluginId(id, reserved);
  if (invalid) throw refusal(invalid);
  if (path.basename(directory) !== id) throw refusal(`The plugin folder "${bounded(path.basename(directory), 64)}" is not named "${id}"`);
  const folder = path.resolve(directory);
  await trusted(folder, `The plugin folder ${directory}`, 'directory');
  const descriptor = path.join(folder, 'runtime.json');
  await trusted(descriptor, 'runtime.json', 'file');
  let value;
  try { value = JSON.parse(await readFile(descriptor, 'utf8')); }
  catch { throw refusal('runtime.json is not valid JSON'); }
  const manifest = readManifest(value, id);
  const label = `The adapter "${bounded(manifest.adapter, 128)}"`;
  const adapter = path.resolve(folder, manifest.adapter);
  if (path.isAbsolute(manifest.adapter) || !adapter.startsWith(folder + path.sep)) throw refusal(`${label} is outside the plugin folder`);
  const info = await trusted(adapter, label, 'file');
  // A link in a folder between the plugin folder and the adapter.
  const [real, realFolder] = await Promise.all([realpath(adapter), realpath(folder)]);
  if (!real.startsWith(realFolder + path.sep)) throw refusal(`${label} is outside the plugin folder`);
  return { id, directory: folder, manifest, adapter, version: `${info.mtimeMs}-${info.size}` };
}

/** Stands in for a plugin that cannot run: offered like any runtime, its start says why. */
function unavailable(id, title, reason) {
  return new (class extends Runtime {
    static id = id;
    static displayName = title;
    async start() { throw new Error(`${id} cannot run: ${reason}`); }
  })();
}

/**
 * The runtime of the plugin `id` (`{ directory, executable }` from the command line): the
 * adapter's factory called with the kit. A plugin that is refused or whose adapter fails is
 * returned as a runtime whose start fails with the reason, so the session reports it like
 * any runtime that cannot start.
 */
export async function loadPlugin(id, { directory, executable }, { toolServers = [], reserved = [] } = {}) {
  let plugin;
  try { plugin = await inspectPlugin(id, directory, { reserved }); }
  catch (error) { return unavailable(id, id, error.message); }
  const title = plugin.manifest.title;
  try {
    // The query names this version of the file: an adapter changed since it was last imported loads again.
    const module = await import(`${pathToFileURL(plugin.adapter).href}?v=${plugin.version}`);
    if (typeof module.default !== 'function') throw new Error('the adapter must default-export a factory function');
    const runtime = await module.default(kit, { executable: executable ?? plugin.manifest.executable, toolServers, options: {} });
    if (!(runtime instanceof Runtime)) throw new Error('the adapter must return a kit.Runtime subclass instance');
    if (runtime.id !== id) throw new Error(`the adapter made a runtime with id "${bounded(runtime.id, 40)}", not "${id}"`);
    return runtime;
  } catch (error) { return unavailable(id, title, bounded(error.message, 2048)); }
}
