// Offline-only desktop restart + independent speech fixture. No upstream forwarding.
import http from 'node:http';
import fs from 'node:fs';
const settings = process.argv[2];
let desktop, peers = new Set(), connects = 0, probes = 0, interrupts = 0;
let posts = [], speech = [], cancelledSpeech = 0, interruptStatus = 500, delayed = false;
let activeReads = 0, maxPeers = 0, interruptResult = false;
const taggedActive = new Set(), taggedCancelled = [];
const taggedText = {
  fresh: 'Tagged fresh reply begins after the fixture restart.',
  pending: 'Pending tagged prefetch must never play after Stop.',
  rebuilt: 'Tagged rebuilt graph reply has a distinct sample ramp.',
};
const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', () => {
  if ([8444, 8446, 8450].includes(server.address().port)) throw Error('reserved port');
  resolve(server.address().port);
}));
const json = (res, data, status = 200) => { res.writeHead(status, {'content-type':'application/json'}); res.end(JSON.stringify(data)); };
async function start() {
  desktop = http.createServer(async (req, res) => {
    if (req.url === '/api/system/info') {
      probes++;
      if (delayed && probes <= 2) return json(res, {error:'unavailable'}, 503);
      return json(res, {runtime:'desktop', openchamberVersion:'fixture'});
    }
    if (req.url === '/api/event') {
      connects++; res.writeHead(200, {'content-type':'text/event-stream'});
      peers.add(res); req.on('close', () => peers.delete(res));
      maxPeers = Math.max(maxPeers, peers.size);
      setTimeout(() => res.write('data: {"type":"server.connected"}\n\n'), 80);
      return;
    }
    if (req.url === '/api/session/active') { activeReads++; return json(res, {data:{}}); }
    if (req.url === '/api/session/ses_fixture') return json(res, {data:{title:'Fixture'}});
    if (req.url === '/api/session/ses_fixture/interrupt?resume=false') {
      interrupts++; return json(res, {interrupted:interruptResult}, interruptStatus);
    }
    if (req.url === '/api/session/ses_fixture/prompt') {
      let body = ''; for await (const chunk of req) body += chunk;
      posts.push(JSON.parse(body)); return json(res, {data:{id:'fixture_receipt'}});
    }
    json(res, {error:'fixture rejects unknown route'}, 404);
  });
  const port = await listen(desktop);
  fs.writeFileSync(settings, JSON.stringify({desktopLocalPort:port}));
  return port;
}
const admin = http.createServer(async (req, res) => {
  if (req.url.startsWith('/interrupt-mode/')) {
    const mode = req.url.split('/').at(-1);
    interruptStatus = mode === 'error' ? 500 : 200; interruptResult = mode === 'true';
    return json(res, {});
  }
  if (req.url === '/restart') {
    for (const peer of peers) peer.destroy(); peers.clear();
    desktop.closeAllConnections(); await new Promise(resolve => desktop.close(resolve));
    delayed = true; probes = 0;
    // Published discovery temporarily points at a refused old listener.
    await new Promise(resolve => setTimeout(resolve, 150));
    return json(res, {port:await start()});
  }
  if (['/reply', '/reply-pending', '/reply-stream'].includes(req.url)) {
    const text = req.url === '/reply-pending' ? 'Pending headers for this synthetic sentence. Queued sentence.' : req.url === '/reply-stream' ? 'Streaming audio for this synthetic sentence. Queued sentence.' : 'Synthetic reply.';
    for (const peer of peers) peer.write('data: '+JSON.stringify({type:'session.text.ended', data:{sessionID:'ses_fixture', assistantMessageID:req.url, text}})+'\n\n');
    return json(res, {});
  }
  if (req.url.startsWith('/tagged/')) {
    const kind = req.url.split('/').at(-1);
    if (!['fresh', 'rebuilt'].includes(kind)) return json(res, {}, 404);
    const text = taggedText[kind] + (kind === 'fresh' ? ' ' + taggedText.pending : '');
    const data = {sessionID:'ses_fixture', assistantMessageID:'tagged_' + kind, ordinal:0};
    const events = [
      {type:'session.execution.started', data:{sessionID:'ses_fixture'}},
      {type:'session.text.started', data},
      {type:'session.text.delta', data:{...data, delta:text.slice(0, 20)}},
      {type:'session.text.delta', data:{...data, delta:text.slice(20)}},
      {type:'session.text.ended', data:{...data, text}},
      {type:'session.execution.succeeded', data:{sessionID:'ses_fixture'}},
    ];
    for (const peer of peers) for (const event of events) peer.write('data: '+JSON.stringify(event)+'\n\n');
    return json(res, {message:data.assistantMessageID});
  }
  if (req.url === '/v1/audio/speech') {
    let body = ''; for await (const chunk of req) body += chunk;
    const input = JSON.parse(body).input;
    speech.push(input);
    const kind = Object.keys(taggedText).find(key => taggedText[key] === input);
    if (kind) {
      taggedActive.add(kind);
      res.on('close', () => {
        taggedActive.delete(kind);
        if (kind === 'fresh' || kind === 'pending') taggedCancelled.push(kind);
      });
      if (kind === 'pending') return;
      res.writeHead(200, {'content-type':'application/octet-stream','x-sample-rate':'48000'});
      const tag = {fresh:2, rebuilt:3}[kind], frames = kind === 'fresh' ? 48000 : 960;
      const pcm = Buffer.alloc(frames * 2);
      for (let i = 0; i < frames; i++) pcm.writeInt16LE(tag * 2048 + i % 1024, i * 2);
      if (kind === 'fresh') res.write(pcm); else res.end(pcm);
      return;
    }
    if (input.startsWith('Pending headers')) { res.on('close', () => cancelledSpeech++); return; }
    res.writeHead(200, {'content-type':'application/octet-stream','x-sample-rate':'48000'});
    const pcm = Buffer.alloc(48000 * 2);
    for (let i = 0; i < 48000; i++) pcm.writeInt16LE(8192, i * 2);
    if (input.startsWith('Streaming audio')) {
      res.write(pcm); res.on('close', () => cancelledSpeech++); return;
    }
    res.end(pcm); return;
  }
  if (req.url === '/stats') return json(res, {connects, probes, interrupts, posts, speech, cancelledSpeech,
    activeReads, peers:peers.size, maxPeers, taggedActive:[...taggedActive], taggedCancelled});
  json(res, {}, 404);
});
const adminPort = await listen(admin); await start();
console.log(adminPort);
setTimeout(() => process.exit(2), 45000).unref(); // owned fixture watchdog only
// Parent closes stdin on test teardown. No persistent/background service.
process.stdin.resume(); process.stdin.on('end', () => {
  for (const peer of peers) peer.destroy();
  desktop.closeAllConnections(); desktop.close(); admin.closeAllConnections(); admin.close();
});
