import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { owned } from './push-store.mjs';

// Only the existing owner-protected sender socket controls this bit. No bearer
// credential grants maintenance authority. Same-UID processes are trusted.
export class Maintenance {
  constructor(directory) {
    this.directory = directory;
    this.file = path.join(directory, 'maintenance.json');
    this.nonce = crypto.randomUUID();
    this.held = true;
    this.invalid = false;
    try {
      owned(path.dirname(directory), 'directory', 0o700);
      owned(directory, 'directory', 0o700);
      let fd;
      try { fd = fs.openSync(this.file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW); }
      catch (e) { if (e.code === 'ENOENT') { this.held = false; return; } throw e; }
      try {
        const s = fs.fstatSync(fd);
        if (!s.isFile() || s.uid !== process.getuid() || (s.mode & 0o777) !== 0o600) throw new Error();
        const value = JSON.parse(fs.readFileSync(fd, 'utf8'));
        if (Object.keys(value).sort().join(',') !== 'held,version' || value.version !== 1 || typeof value.held !== 'boolean') throw new Error();
        this.held = value.held;
      } finally { fs.closeSync(fd); }
    } catch { this.invalid = true; }
  }
  requireOpen() {
    if (this.held) throw Object.assign(new Error('bridge maintenance hold'), { status: 503 });
  }
  write(held) {
    // Failure always closes admission in this process; never acknowledges success.
    this.held = true;
    try {
      owned(path.dirname(this.directory), 'directory', 0o700);
      owned(this.directory, 'directory', 0o700);
      try { owned(this.file, 'file', 0o600); } catch (e) { if (e.code !== 'ENOENT') throw e; }
      const tmp = path.join(this.directory, `.maintenance-${crypto.randomUUID()}`);
      let created = false;
      try {
        const fd = fs.openSync(tmp, 'wx', 0o600);
        created = true;
        try { fs.writeFileSync(fd, JSON.stringify({ version: 1, held })); fs.fsyncSync(fd); }
        finally { fs.closeSync(fd); }
        fs.renameSync(tmp, this.file);
        const dir = fs.openSync(this.directory, 'r');
        try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
      } finally { if (created) { try { fs.unlinkSync(tmp); } catch (e) { if (e.code !== 'ENOENT') throw e; } } }
      this.held = held; this.invalid = false;
    } catch (e) { this.invalid = true; throw e; }
  }
  status() {
    const counts = this.counts();
    return { pid: process.pid, nonce: this.nonce, held: this.held, invalid: this.invalid,
      listening: this.listening(), counts,
      localQuiet: this.held && !this.invalid && !this.listening() && !this.sealing && Object.values(counts).every(n => n === 0),
      remoteCompletion: 'unproven; remote work may continue' };
  }
  async command(action) {
    if (action === 'status') { await this.refresh?.(); return this.status(); }
    if (this.changing) throw Object.assign(new Error('maintenance transition pending'), { status: 409 });
    this.changing = true;
    try {
      if (action === 'hold') this.write(true);
      else if (action === 'seal') {
        await this.refresh?.();
        const s = this.status();
        if (!s.held || s.invalid || this.sealing || Object.values(s.counts).some(n => n !== 0)) throw Object.assign(new Error('bridge still draining'), { status: 409 });
        this.sealing = true;
        try { await this.stopListening(); } finally { this.sealing = false; }
      } else if (action === 'release') {
        this.write(false);
        try { await this.startListening(); } catch (e) { this.write(true); throw e; }
      } else throw Object.assign(new Error('unknown maintenance command'), { status: 400 });
      return this.status();
    } finally { this.changing = false; }
  }
}
