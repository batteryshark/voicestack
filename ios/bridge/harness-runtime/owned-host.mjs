// Private, exact-version SDK embedding. No principal service discovery or auth import.
import fs from 'node:fs';
import path from 'node:path';
import { Effect, Layer } from 'effect';
import { Config } from '@opencode/core/config';
import { SessionRestart } from '@opencode/core/session/execution/restart';
// This internal entrypoint is deliberately pinned: the public Promise wrapper
// drops EmbedOptions, which are required to disable system/global discovery.
import { EmbeddedHost } from './node_modules/@opencode/sdk/dist/internal/host.js';

export function validateOwnedRoot(root) {
  if (typeof root !== 'string' || !path.isAbsolute(root) || fs.realpathSync(root) !== root) throw new Error('owned_root_required');
  const owned = directory => {
    const st = fs.lstatSync(directory);
    if (!st.isDirectory() || st.isSymbolicLink() || st.uid !== process.getuid() || (st.mode & 0o777) !== 0o700) throw new Error('owned_directory_required');
  };
  owned(root);
  for (const [key, name] of Object.entries({ HOME: 'home', XDG_CONFIG_HOME: 'config', XDG_DATA_HOME: 'data', XDG_CACHE_HOME: 'cache', XDG_STATE_HOME: 'state' })) {
    const directory = path.join(root, name);
    if (process.env[key] !== directory) throw new Error('isolated_process_environment_required');
    owned(directory);
  }
}

export async function createOwnedHost({ root, plugins = [], overrides = [], bundledModels = false }) {
  validateOwnedRoot(root);
  for (const name of ['sdk', 'core']) {
    const metadata = JSON.parse(fs.readFileSync(new URL(`./node_modules/@opencode/${name}/package.json`, import.meta.url)));
    if (metadata.version !== '2.0.32') throw new Error('runtime_version_mismatch');
  }
  const database = path.join(root, 'harness.sqlite');
  const existing = fs.lstatSync(database, { throwIfNoEntry: false });
  if (existing && (!existing.isFile() || existing.isSymbolicLink() || existing.uid !== process.getuid() || existing.nlink !== 1)) throw new Error('owned_database_required');
  const host = await Effect.runPromise(EmbeddedHost.create({
    database: { path: database },
    config: { directory: path.join(root, 'config'), project: false, claude: false },
    models: { fetch: false, snapshot: bundledModels },
    fs: { filewatcher: false, fff: false },
    pty: { root: path.join(root, 'pty') },
    events: { persist: true },
    plugins,
    log: { level: 'error', emit: () => {} },
  }, { overrides: [Config.node.replace(Config.configured({
    project: false, global: false, system: false, claude: false, content: '{}',
  })), SessionRestart.node.replace(Layer.succeed(SessionRestart.Service, {
    // A process loss never authorizes at-least-once tool resumption here.
    resumeSuspendedSessions: Effect.void,
  })), ...overrides] }));
  let closing, closed = false;
  return {
    // Internal owner only; not an authenticated exchange-completion capability.
    host,
    database,
    stats: () => ({ closed }),
    close() {
      return closing ??= host.close().then(() => { closed = true; });
    },
  };
}
