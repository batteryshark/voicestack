import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { owned } from './push-store.mjs';
import { requireThat } from './reachout-policy.mjs';

const DAY = 24 * 60 * 60 * 1000;
export function validOverride(value, now) {
  return value && Object.keys(value).sort().join(',') === 'enabled,reason,setAt,until,version'
    && value.version === 1 && typeof value.enabled === 'boolean'
    && Number.isSafeInteger(value.setAt) && value.setAt >= 0 && value.setAt <= now
    && Number.isSafeInteger(value.until) && value.until >= value.setAt
    && (!value.enabled || value.until > value.setAt) && value.until - value.setAt <= DAY
    && typeof value.reason === 'string' && value.reason.trim().length > 0 && value.reason.length <= 160
    && !/[\x00-\x1f\x7f]/.test(value.reason);
}
export function readDevOverride(directory, now = Date.now()) {
  let fd;
  try {
    if (!directory) return { active: false };
    owned(directory, 'directory', 0o700);
    fd = fs.openSync(path.join(directory, 'dev-override.json'), fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o777) !== 0o600 || stat.nlink !== 1 || stat.size > 4096) return { active: false };
    const value = JSON.parse(fs.readFileSync(fd, 'utf8'));
    return validOverride(value, now) ? { ...value, active: value.enabled && now < value.until } : { active: false };
  } catch { return { active: false }; }
  finally { if (fd !== undefined) fs.closeSync(fd); }
}
export function writeDevOverride(directory, { enabled, minutes, reason }, now = Date.now()) {
  owned(directory, 'directory', 0o700); // Existing private storage only; never create another policy location.
  if (enabled) requireThat(Number.isInteger(minutes) && minutes >= 1 && minutes <= 1440, 400, 'minutes must be 1..1440');
  const value = { version: 1, enabled, until: enabled ? now + minutes * 60000 : now, reason: enabled ? reason?.trim() : 'Disabled', setAt: now };
  requireThat(validOverride(value, now), 400, 'invalid development override');
  const temporary = path.join(directory, '.dev-override-' + crypto.randomUUID());
  let created = false;
  try {
    const fd = fs.openSync(temporary, 'wx', 0o600);
    created = true;
    fs.fchmodSync(fd, 0o600);
    try { fs.writeFileSync(fd, JSON.stringify(value) + '\n'); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    fs.renameSync(temporary, path.join(directory, 'dev-override.json'));
    const dir = fs.openSync(directory, 'r');
    try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
  } finally {
    if (created) { try { fs.unlinkSync(temporary); } catch (error) { if (error.code !== 'ENOENT') throw error; } }
  }
  return readDevOverride(directory, now);
}
