import http2 from 'node:http2';
import crypto from 'node:crypto';
import fs from 'node:fs';
import { CONFIG } from './reachout-policy.mjs';
export function jwt(key, now = Date.now(), config = CONFIG) {
  const encode = x => Buffer.from(JSON.stringify(x)).toString('base64url');
  const input = encode({ alg: 'ES256', kid: config.keyID }) + '.' + encode({ iss: config.teamID, iat: Math.floor(now / 1000) });
  return input + '.' + crypto.sign('sha256', Buffer.from(input), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
}
// Key loading is confined to an explicit send, never import/startup/dry-run.
export function createAPNs({ config = CONFIG, readKey = () => fs.readFileSync(config.keyPath), connect = http2.connect, now = Date.now } = {}) {
  // Memory only. APNs permits provider-token rotation every 20–60 minutes.
  // Synchronous signing makes concurrent sends share a single refresh/key read.
  let cached;
  return async ({ token, environment, voip, payload, collapseID }) => {
    const time = now();
    try {
      if (!cached || time - cached.createdAt >= 40 * 60000) cached = { value: jwt(readKey(), time, config), createdAt: time };
    } catch { throw new Error('APNs provider unavailable'); }
    const authorization = cached.value;
    const origin = environment === 'sandbox' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com';
    return new Promise((resolve, reject) => {
      let client, request, settled = false;
      const finish = (error, result) => { if (settled) return; settled = true; clearTimeout(timer); request?.close(); client?.destroy(); error ? reject(new Error('APNs delivery unknown')) : resolve(result); };
      const timer = setTimeout(() => finish(true), 10000);
      try {
        client = connect(origin); client.on('error', () => finish(true));
        request = client.request({ ':method': 'POST', ':path': '/3/device/' + token,
          authorization: 'bearer ' + authorization, 'content-type': 'application/json', 'apns-topic': config.topic + (voip ? '.voip' : ''),
          'apns-push-type': voip ? 'voip' : 'alert', 'apns-priority': '10',
          'apns-expiration': voip ? '0' : String(Math.floor(now() / 1000) + config.notificationTTL),
          ...(voip ? {} : { 'apns-collapse-id': crypto.createHash('sha256').update(collapseID).digest('hex') }) });
        let status, n = 0;
        request.on('response', headers => { status = Number(headers[':status']); });
        request.on('data', chunk => { n += chunk.length; if (n > 4096) finish(true); });
        request.on('error', () => finish(true));
        request.on('end', () => status ? finish(false, { status }) : finish(true));
        request.on('close', () => { if (!settled) finish(true); });
        request.end(JSON.stringify(payload));
      } catch { finish(true); }
    });
  };
}
