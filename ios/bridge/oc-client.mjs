// Voicestack's own desktop client only. No borrowed credentials or token output.
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import { fileURLToPath } from 'node:url';

export const defaultBinding = process.env.FV_OC_CLIENT_DIR
  ? path.join(process.env.FV_OC_CLIENT_DIR, 'client.json')
  : fileURLToPath(new URL('../private/openchamber/client.json', import.meta.url));
export class OCError extends Error {
  constructor(category = 'binding_invalid') {
    super('Mac connection needs re-pairing'); this.status = 503; this.category = category;
  }
}
export function discoverDesktop() {
  try {
    const { desktopLocalPort: port } = JSON.parse(fs.readFileSync(path.join(process.env.HOME, '.config/openchamber/settings.json')));
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error();
    return port;
  } catch { throw new OCError('desktop_unavailable'); }
}
function originPort(origin) {
  try {
    const u = new URL(origin);
    if (u.protocol !== 'http:' || !['127.0.0.1', '[::1]'].includes(u.hostname)
      || u.username || u.password || u.search || u.hash || u.pathname !== '/' || !u.port
      || ![u.origin, u.origin + '/'].includes(origin)) throw new Error();
    return u;
  } catch { throw new OCError('host_unverified'); }
}
async function request(origin, route, headers = {}, signal) {
  const u = originPort(origin);
  return new Promise((resolve, reject) => {
    const req = http.request({ hostname: u.hostname === '[::1]' ? '::1' : u.hostname,
      port: u.port, path: route, method: 'GET', headers, signal }, res => {
      let size = 0; const chunks = [];
      res.on('data', c => { size += c.length; if (size > 65536) res.destroy(); else chunks.push(c); });
      res.on('error', () => reject(new OCError('host_unavailable')));
      res.on('end', () => {
        if (res.statusCode !== 200) { resolve({ status: res.statusCode, body: null }); return; }
        try { resolve({ status: res.statusCode, body: JSON.parse(Buffer.concat(chunks)) }); }
        catch { reject(new OCError('host_unavailable')); }
      });
    });
    const timer = setTimeout(() => req.destroy(), 5000);
    req.once('close', () => clearTimeout(timer));
    req.on('error', () => reject(new OCError('host_unavailable'))); req.end();
  });
}

export class OpenChamberClient {
  #binding; #signature; #paired = false; #absentLogged = false;
  constructor({ file = defaultBinding, diagnostic = () => {} } = {}) {
    this.file = file; this.diagnostic = diagnostic;
  }
  note(category) { try { this.diagnostic({ stage: 'oc_auth', category }); } catch { /* closed diagnostics only */ } }
  load(force = false) {
    let fd;
    try {
      // A removed binding after pairing is NOT permission to fall back to no auth.
      if (!fs.lstatSync(this.file, { throwIfNoEntry: false })) {
        if (this.#paired) throw new Error();
        if (!this.#absentLogged) { this.note('binding_absent'); this.#absentLogged = true; }
        return null;
      }
      this.#paired = true;
      const dir = fs.lstatSync(path.dirname(this.file));
      if (!dir.isDirectory() || dir.uid !== process.getuid() || (dir.mode & 0o777) !== 0o700) throw new Error();
      try { fd = fs.openSync(this.file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK); }
      catch (e) {
        if (e.code !== 'ENOENT' || this.#paired || fs.lstatSync(this.file, { throwIfNoEntry: false })) throw new Error();
        if (!this.#absentLogged) { this.note('binding_absent'); this.#absentLogged = true; }
        return null;
      }
      this.#paired = true;
      const st = fs.fstatSync(fd);
      if (!st.isFile() || st.uid !== process.getuid() || (st.mode & 0o777) !== 0o600 || st.nlink !== 1 || st.size > 65536) throw new Error();
      const signature = [st.dev, st.ino, st.size, st.mtimeMs, st.ctimeMs].join(':');
      if (!force && signature === this.#signature) return this.#binding;
      const b = JSON.parse(fs.readFileSync(fd, 'utf8'));
      if (b.version !== 1 || typeof b.clientId !== 'string' || !b.clientId || b.clientKind !== 'desktop'
        || typeof b.label !== 'string' || !b.label || typeof b.clientToken !== 'string'
        || !/^oc_client_[A-Za-z0-9_-]+$/.test(b.clientToken)) throw new Error();
      originPort(b.enrolledOrigin);
      this.#binding = b; this.#signature = signature; this.#absentLogged = false;
      return b;
    } catch {
      this.#paired = true; this.#binding = undefined; this.#signature = undefined;
      this.note('binding_invalid'); throw new OCError();
    } finally { if (fd !== undefined) fs.closeSync(fd); }
  }
  async prepare(port, signal) {
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new OCError('host_unverified');
    return this.prepareOrigin(`http://127.0.0.1:${port}`, signal);
  }
  async prepareOrigin(origin, signal) {
    const u = originPort(origin), binding = this.load();
    // Bridge transport is explicitly IPv4 loopback; do not verify one host and send to another.
    if (u.hostname !== '127.0.0.1') throw new OCError('host_unverified');
    if (!binding) return { port: Number(u.port), headers: {}, paired: false };
    const health = await request(origin, '/health', {}, signal);
    if (health.status !== 200 || typeof health.body?.openchamberVersion !== 'string' || !health.body.openchamberVersion) {
      this.note('host_unverified'); throw new OCError('host_unverified');
    }
    return { port: Number(u.port), headers: { Authorization: `Bearer ${binding.clientToken}` }, paired: true };
  }
  rejected() {
    this.note('auth_rejected');
    try { this.load(true); } catch { /* never retry or fall back, even after re-reading */ }
    return new OCError('auth_rejected');
  }
  async check(discover = discoverDesktop) {
    const binding = this.load();
    if (!binding) return { bindingExists: false, ownRecordMatches: false, hostEnforcedAuthentication: 'not proven' };
    const port = discover(), origin = `http://127.0.0.1:${port}`;
    const context = await this.prepare(port);
    const result = await request(origin, '/api/client-auth/clients', context.headers);
    if ([401, 403].includes(result.status)) throw this.rejected();
    const clients = result.body?.clients;
    const ownRecordMatches = result.status === 200 && Array.isArray(clients) && clients.length === 1
      && clients[0]?.id === binding.clientId && clients[0]?.clientKind === 'desktop'
      && !clients[0]?.revokedAt && !clients[0]?.expiresAt;
    this.note(ownRecordMatches ? 'own_record_matches' : 'own_record_mismatch');
    return { bindingExists: true, ownRecordMatches, hostEnforcedAuthentication: 'not proven' };
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv[2] !== 'check' || process.argv.length > 4) throw new OCError();
    const result = await new OpenChamberClient({ file: process.argv[3] || defaultBinding }).check();
    console.log(JSON.stringify(result));
    if (result.bindingExists && !result.ownRecordMatches) process.exitCode = 1;
  } catch { console.log(JSON.stringify({ ownRecordMatches: false, status: 'Mac connection needs re-pairing' })); process.exitCode = 1; }
}
