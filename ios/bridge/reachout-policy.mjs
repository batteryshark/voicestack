// One reviewable set of provisional defaults. No Focus bypass / Critical Alerts.
export const CONFIG = Object.freeze({ policyVersion: 1, callsEnabled: true, quietHoursEnabled: true,
  quietStart: '22:00', quietEnd: '09:00', policyFreshMs: 86400000,
  ringMs: 30000, fallbackMs: 45000, callSpacingMs: 900000, callsPerDay: 3,
  notificationsPerHour: 6, notificationTTL: 3600, maxRecords: 10000,
  dispatchConcurrency: 2, dispatchQueueLimit: 32,
  // Nonsecret operator policy. Empty configuration denies install links.
  deploymentSuffix: process.env.FV_INSTALL_DEPLOYMENT_SUFFIX || '',
  approvedManifests: JSON.parse(process.env.FV_APPROVED_INSTALL_MANIFESTS || '[]'), keyPath: process.env.FV_APNS_KEY_PATH || '',
  keyID: process.env.FV_APNS_KEY_ID || '', teamID: process.env.FV_APPLE_TEAM_ID || '', topic: process.env.FV_BUNDLE_ID || 'org.example.voicestack' });
export function requireThat(ok, status = 400, message = 'invalid push schema') {
  if (!ok) throw Object.assign(new Error(message), { status });
}
export function exact(o, fields) {
  requireThat(o && typeof o === 'object' && !Array.isArray(o) && Object.keys(o).every(k => fields.includes(k)));
}
export const stableID = s => typeof s === 'string' && /^[A-Za-z0-9_-]{1,100}$/.test(s);
const text = (s, n) => typeof s === 'string' && s.trim().length > 0 && s.length <= n && !/[\x00-\x1f\x7f]/.test(s);
const revision = n => Number.isSafeInteger(n) && n > 0;
export function validZone(zone) {
  if (typeof zone !== 'string' || zone.length > 100) return false;
  try { new Intl.DateTimeFormat('en-US', { timeZone: zone }).format(0); return true; } catch { return false; }
}
export const validTime = s => typeof s === 'string' && /^(?:[01]\d|2[0-3]):[0-5]\d$/.test(s);
export function settingsSchema(o) {
  exact(o, ['callsEnabled', 'quietHoursEnabled', 'quietStart', 'quietEnd', 'timeZone', 'policyVersion', 'revision']);
  requireThat(typeof o.callsEnabled === 'boolean' && typeof o.quietHoursEnabled === 'boolean' && validTime(o.quietStart) && validTime(o.quietEnd)
    && validZone(o.timeZone) && o.policyVersion === CONFIG.policyVersion && revision(o.revision));
  return { ...o };
}
export function enrollmentSchema(o) {
  exact(o, ['alertToken', 'voipToken', 'environment', 'build', 'revision']);
  requireThat(['sandbox', 'production'].includes(o.environment) && text(o.build, 40) && revision(o.revision));
  for (const k of ['alertToken', 'voipToken']) requireThat(o[k] === null || (typeof o[k] === 'string' && /^[a-fA-F0-9]{64,512}$/.test(o[k]) && o[k].length % 2 === 0));
  return { ...o, alertToken: o.alertToken?.toLowerCase() ?? null, voipToken: o.voipToken?.toLowerCase() ?? null };
}
// Common strict URI spelling, checked before any URL-library normalization.
const strictURI = s => typeof s === 'string' && s.length > 0 && !/[^A-Za-z0-9._~:/?@!$&'()*+,;=%-]/.test(s) && !/%(?![0-9a-fA-F]{2})/.test(s);
export function manifestAllowed(value, config = CONFIG) {
  try {
    if (!strictURI(value) || !value.startsWith('itms-services://?')) return false;
    // URLComponents queryItems semantics: '+' is literal, not form-encoded space.
    const items = value.slice('itms-services://?'.length).split('&').map(item => {
      const at = item.indexOf('=');
      return [decodeURIComponent(at < 0 ? item : item.slice(0, at)), at < 0 ? null : decodeURIComponent(item.slice(at + 1))];
    });
    if (items.length !== 2 || items.filter(([name, val]) => name === 'action' && val === 'download-manifest').length !== 1) return false;
    const raw = items.find(([name]) => name === 'url')?.[1];
    if (!strictURI(raw)) return false;
    // Reject even empty userinfo, which WHATWG URL would otherwise erase.
    const authority = /^https:\/\/([^/?#]*)/.exec(raw)?.[1];
    if (!authority || !/^[A-Za-z0-9.-]+(?::[0-9]{1,5})?$/.test(authority)) return false;
    const port = authority.split(':')[1];
    if (port !== undefined && Number(port) > 65535) return false;
    const inner = new URL(raw);
    let host = inner.hostname.toLowerCase();
    if (host.endsWith('.')) host = host.slice(0, -1);
    if (!host || host.endsWith('.') || host.startsWith('.') || host.includes('..')) return false;
    // DNS structure is not proof of ownership. Only explicit operator policy permits.
    const dns = /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+ts\.net$/;
    if (inner.protocol !== 'https:' || inner.username || inner.password || host.length > 253 || !dns.test(host)) return false;
    const suffix = config.deploymentSuffix === undefined ? '' : config.deploymentSuffix, approved = config.approvedManifests;
    if (typeof suffix !== 'string' || !Array.isArray(approved) || !approved.every(x => typeof x === 'string')) return false;
    if (suffix !== '') {
      if (!suffix.startsWith('.') || suffix.length > 254 || !dns.test(suffix.slice(1))) return false;
      return host.endsWith(suffix) && (approved.length === 0 || approved.includes(raw));
    }
    return approved.length > 0 && approved.includes(raw);
  } catch { return false; }
}
export const REACHOUT_REASONS = Object.freeze({ need: ['decision', 'hands', 'stuck'], 'ready-to-try': ['install', 'build'], 'urgent-call': ['decision', 'goal-risk'] });
export function sendSchema(o, config = CONFIG) {
  exact(o, ['kind', 'reason', 'session', 'id', 'title', 'body', 'url', 'messageID', 'expiresIn']);
  const reasons = REACHOUT_REASONS;
  requireThat(Object.hasOwn(reasons, o.kind) && reasons[o.kind].includes(o.reason));
  requireThat(typeof o.session === 'string' && /^ses_[A-Za-z0-9]{1,100}$/.test(o.session) && stableID(o.id) && text(o.title, 100) && text(o.body, 1000));
  requireThat(o.messageID === undefined || (typeof o.messageID === 'string' && /^[A-Za-z0-9_-]{1,200}$/.test(o.messageID)));
  requireThat(o.url === undefined || (o.kind === 'ready-to-try' && manifestAllowed(o.url, config)));
  requireThat(o.expiresIn === undefined || (o.kind === 'urgent-call' && Number.isInteger(o.expiresIn) && o.expiresIn >= 30 && o.expiresIn <= 300));
  requireThat(!/\bmilestone\b/i.test(o.title + ' ' + o.body), 400, 'milestone news is not a reach-out');
  return { ...o };
}
export function localParts(now, zone) {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(now);
  const p = Object.fromEntries(parts.map(p => [p.type, p.value]));
  return { minute: Number(p.hour) * 60 + Number(p.minute), day: `${p.year}-${p.month}-${p.day}` };
}
export function isQuiet(settings, now) {
  if (!settings.quietHoursEnabled) return false;
  const minute = s => Number(s.slice(0, 2)) * 60 + Number(s.slice(3));
  const t = localParts(now, settings.timeZone).minute, start = minute(settings.quietStart), end = minute(settings.quietEnd);
  return start === end || (start < end ? t >= start && t < end : t >= start || t < end);
}
export function callPolicy(settings, now, config = CONFIG) {
  if (!settings || now - settings.syncedAt >= config.policyFreshMs || settings.syncedAt > now) return 'policy-stale';
  if (!validZone(settings.timeZone)) return 'invalid-time-zone';
  if (!settings.callsEnabled) return 'calls-off';
  if (isQuiet(settings, now)) return 'quiet-hours';
  return 'urgent-eligible';
}
