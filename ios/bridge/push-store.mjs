import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { requireThat } from './reachout-policy.mjs';
export function owned(file, kind, mode) {
  const s = fs.lstatSync(file);
  requireThat((kind === 'directory' ? s.isDirectory() : kind === 'socket' ? s.isSocket() : s.isFile()) && s.uid === process.getuid() && (s.mode & 0o777) === mode, 503, 'private push storage required');
}
export class PushStore {
  constructor(directory) {
    this.directory = directory;
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    owned(directory, 'directory', 0o700);
    this.file = path.join(directory, 'state.json');
    this.data = { devices: {}, records: {} };
    if (fs.existsSync(this.file)) { owned(this.file, 'file', 0o600); this.data = JSON.parse(fs.readFileSync(this.file)); }
  }
  save() {
    owned(this.directory, 'directory', 0o700);
    const tmp = path.join(this.directory, `.state-${crypto.randomUUID()}`);
    let created = false;
    try {
      const fd = fs.openSync(tmp, 'wx', 0o600);
      created = true;
      try { fs.writeFileSync(fd, JSON.stringify(this.data)); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
      fs.renameSync(tmp, this.file);
      const dir = fs.openSync(this.directory, 'r');
      try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
    } finally {
      // An unsuccessful atomic replacement must not leave an extra token-bearing file.
      if (created) { try { fs.unlinkSync(tmp); } catch (e) { if (e.code !== 'ENOENT') throw e; } }
    }
  }
  openVoice() {
    return this.data.openVoice ??= { grants: {}, mappings: {}, calls: {}, capabilities: {} };
  }
}
