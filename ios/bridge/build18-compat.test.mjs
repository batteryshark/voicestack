import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { pathToFileURL } from 'node:url';
import { createBridge } from './server.mjs';

const exec = promisify(execFile);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
test('unmodified build-18 HTTP transport/parser accepts new-bridge comments, clean rotation and a fresh connection', { timeout: 30000 }, async () => {
  const env = { ...process.env, DEVELOPER_DIR: '/Applications/Xcode.app/Contents/Developer' };
  const { stdout: source } = await exec('git', ['show', '4d572b1:app/Sources/FloatingVoiceCore/HTTPStream.swift'], { cwd: root });
  const parent = path.join(root, 'output', 'compatibility');
  await fs.mkdir(parent, { recursive: true });
  const dir = await fs.mkdtemp(path.join(parent, 'build18-'));
  await fs.writeFile(path.join(dir, 'Build18.swift'), source);
  // Logging-only stubs: the HTTP transport and SSE parser are the exact build-18 source.
  await fs.writeFile(path.join(dir, 'Diagnostics.swift'), `import Foundation
enum DiagnosticStage { case other, events, tts }
enum DiagnosticCategory { case begin, ready, complete, failed }
final class StageDiagnostics {
 static let shared = StageDiagnostics()
 func record(_ stage: DiagnosticStage, _ category: DiagnosticCategory, since: Date = Date(), status: Int? = nil) {}
 static func code(_ error: Error) -> Int { (error as NSError).code }
}
`);
  await fs.writeFile(path.join(dir, 'Main.swift'), `import Foundation
@main struct CompatibilityClient {
 static func main() async throws {
  var totalEvents = 0
  for attempt in 1...2 {
   var request = URLRequest(url: URL(string: CommandLine.arguments[1])!)
   request.setValue("fixture", forHTTPHeaderField: "X-FV-Generation")
   let stream = HTTPChunkStream(request, idleTimeout: 75)
   guard try await stream.headers().statusCode == 200 else { throw HTTPError.noResponse }
   var parser = SSEParser(), bytes = Data(), events: [String] = []
   for try await chunk in stream.chunks { bytes.append(chunk); events += parser.push(chunk) }
   guard !parser.exceededLimit, !events.isEmpty,
         String(decoding: bytes, as: UTF8.self).contains(": heartbeat"),
         events.allSatisfy({ !$0.contains(": heartbeat") }) else { throw HTTPError.noResponse }
   totalEvents += events.count
   print("build18 connection=\\(attempt) cleanEOF=true commentsIgnored=true events=\\(events.count)")
  }
  print("build18 compatibility PASS events=\\(totalEvents)")
 }
}
`);
  const binary = path.join(dir, 'client');
  await exec('xcrun', ['swiftc', '-parse-as-library', path.join(dir, 'Build18.swift'), path.join(dir, 'Diagnostics.swift'), path.join(dir, 'Main.swift'), '-o', binary], { env, timeout: 20000 });
  const logs = [];
  const upstream = http.createServer((req, res) => {
    if (req.url === '/api/system/info') { res.end('{"runtime":"desktop"}'); return; }
    assert.equal(req.url, '/api/event');
    res.writeHead(200, { 'Content-Type': 'text/event-stream' }); res.flushHeaders();
    let tick = 0;
    const timer = setInterval(() => res.write(`data: ${JSON.stringify({ type: 'fixture', data: { sessionID: 'ses_fixture', tick: tick++ } })}\n\n`), 25);
    res.on('close', () => clearInterval(timer));
  });
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  // Advance only bridge lifetime scheduling 1000x; client networking is real URLSession.
  const clock = {
    setTimeout: (fn, ms) => setTimeout(fn, ms / 1000), clearTimeout,
    setInterval: (fn, ms) => setInterval(fn, ms / 1000), clearInterval,
  };
  const bridge = createBridge({ credentials: { device: () => ({ sessionID: 'ses_fixture', generation: 'fixture' }) },
    discover: () => upstream.address().port, eventClock: clock, diagnostic: e => logs.push(e) });
  bridge.listen(0, '127.0.0.1'); await once(bridge, 'listening');
  try {
    const url = `http://127.0.0.1:${bridge.address().port}/floating-voice/v1/sessions/ses_fixture/events`;
    const { stdout } = await exec(binary, [url], { env, timeout: 10000 });
    assert.match(stdout, /connection=1 cleanEOF=true commentsIgnored=true/);
    assert.match(stdout, /connection=2 cleanEOF=true commentsIgnored=true/);
    assert.equal(logs.filter(e => e.reason === 'rotation').length, 2);
    await fs.writeFile(path.join(parent, 'build18-new-bridge.log'), stdout);
  } finally {
    bridge.shutdown(); upstream.closeAllConnections(); await new Promise(resolve => upstream.close(resolve));
  }
});

test('new client handles the build-18 bridge/client 75s quiet-close race and reconnects read-only', { timeout: 120000 }, async () => {
  const env = { ...process.env, DEVELOPER_DIR: '/Applications/Xcode.app/Contents/Developer' };
  const parent = path.join(root, 'output', 'compatibility');
  await fs.mkdir(parent, { recursive: true });
  const dir = await fs.mkdtemp(path.join(parent, 'old-bridge-'));
  const { stdout: oldServer } = await exec('git', ['show', '4d572b1:bridge/server.mjs'], { cwd: root });
  const oldPath = path.join(dir, 'build18-server.mjs');
  await fs.writeFile(oldPath, oldServer);
  const { createBridge: oldBridge } = await import(pathToFileURL(oldPath).href);
  await fs.writeFile(path.join(dir, 'Diagnostics.swift'), `import Foundation
enum DiagnosticStage { case other, events, tts }
enum DiagnosticCategory { case begin, ready, complete, failed }
enum NetworkCloseReason: String { case cleanEnd, cancelled, transport, idleTimeout }
enum NetworkCloseInitiator { case client, peer, watchdog }
public enum StreamCancellationCause { case pathChange, watchdog, selection, background, explicit, ownerChanged, lifecycle, consumer }
public enum CaptureField: String, Sendable { case streaming, bytesReceived, chunksReceived, firstByteMs, requestTotalMs, chunkGapMaxMs, chunkGapP95Ms, chunkGapSamples, chunkGapClipped, chunkGapBucketMs }
public struct CaptureSnapshot { init(_ fields: [CaptureField: Double]) {} }
public final class StageDiagnostics: @unchecked Sendable {
 public static let shared = StageDiagnostics()
 var playbackCallToken: Int { 0 }
 private let lock = NSLock(); private var values: [String] = []
 var reasons: [String] { lock.lock(); defer { lock.unlock() }; return values }
 func record(_ stage: DiagnosticStage, _ category: DiagnosticCategory, since: Date = Date(), status: Int? = nil, audio: CaptureSnapshot? = nil,
             attempt: UUID? = nil, initiator: NetworkCloseInitiator? = nil, reason: NetworkCloseReason? = nil, cancellationCause: StreamCancellationCause? = nil, playbackEvent: PlaybackEvent? = nil, callBank: Int? = nil) {
  lock.lock(); defer { lock.unlock() }; if let reason { values.append(reason.rawValue) }
 }
 static func code(_ error: Error) -> Int { (error as NSError).code }
}
`);
  await fs.writeFile(path.join(dir, 'Main.swift'), `import Foundation
@main struct LegacyBridgeClient {
 static func main() async throws {
  let url = URL(string: CommandLine.arguments[1])!
  func request() -> URLRequest { var r = URLRequest(url: url); r.setValue("fixture", forHTTPHeaderField: "X-FV-Generation"); return r }
  let began = ProcessInfo.processInfo.systemUptime
  let quiet = HTTPChunkStream(request(), idleTimeout: 95)
  _ = try await quiet.headers()
  do { for try await _ in quiet.chunks {}; throw HTTPError.noResponse }
  catch {
   // The old bridge also has a real 75s upstream socket timeout. Either side may win.
   guard StageDiagnostics.shared.reasons.contains(where: { ["idleTimeout", "transport", "cleanEnd"].contains($0) }) else {
    print("unexpected quiet close reasons=\\(StageDiagnostics.shared.reasons) error=\\(error)"); fflush(stdout); throw error
   }
  }
  let elapsed = ProcessInfo.processInfo.systemUptime - began
  print("quiet-close elapsed=\\(elapsed) reasons=\\(StageDiagnostics.shared.reasons)"); fflush(stdout)
  guard elapsed >= 74 && elapsed < 90 else { throw HTTPError.noResponse }
  var backoff = ReconnectBackoff()
  let delay = backoff.next(healthyFor: 0, jitter: 0.5)
  try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
  let next = HTTPChunkStream(request(), idleTimeout: 95)
  guard try await next.headers().statusCode == 200 else { throw HTTPError.noResponse }
  var parser = SSEParser(), received: [String] = []
  for try await chunk in next.chunks { received += parser.push(chunk) }
  guard received.count == 1 else { throw HTTPError.noResponse }
  print("new-client/old-bridge PASS quietCloseSeconds=\\(elapsed) closeReasons=\\(StageDiagnostics.shared.reasons) reconnectDelay=\\(delay) events=\\(received.count) mutations=0")
 }
}
`);
  const binary = path.join(dir, 'client');
  await exec('xcrun', ['swiftc', '-parse-as-library', path.join(root, 'app/Sources/FloatingVoiceCore/HTTPStream.swift'),
    path.join(root, 'app/Sources/FloatingVoiceCore/NetworkPolicy.swift'), path.join(root, 'app/Sources/FloatingVoiceCore/PlaybackDiagnostics.swift'), path.join(dir, 'Diagnostics.swift'), path.join(dir, 'Main.swift'), '-o', binary], { env, timeout: 20000 });
  let connections = 0;
  const methods = [];
  const upstream = http.createServer((req, res) => {
    methods.push(req.method); assert.equal(req.method, 'GET');
    if (req.url === '/api/system/info') { res.end('{"runtime":"desktop"}'); return; }
    assert.equal(req.url, '/api/event'); connections += 1;
    res.writeHead(200, { 'Content-Type': 'text/event-stream' });
    res.write(': upstream connected\n\n');
    if (connections === 2) {
      res.end('data: {"type":"fixture","data":{"sessionID":"ses_fixture"}}\n\n');
    }
  });
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  const bridge = oldBridge({ credentials: { device: () => ({ sessionID: 'ses_fixture', generation: 'fixture' }) }, discover: () => upstream.address().port });
  bridge.listen(0, '127.0.0.1'); await once(bridge, 'listening');
  try {
    const url = `http://127.0.0.1:${bridge.address().port}/floating-voice/v1/sessions/ses_fixture/events`;
    const { stdout } = await exec(binary, [url], { env, timeout: 100000 });
    assert.match(stdout, /new-client\/old-bridge PASS/);
    assert.equal(connections, 2); assert(methods.every(m => m === 'GET'));
    await fs.writeFile(path.join(parent, 'new-client-build18-bridge.log'), stdout);
  } finally {
    bridge.shutdown(); upstream.closeAllConnections(); await new Promise(resolve => upstream.close(resolve));
  }
});
