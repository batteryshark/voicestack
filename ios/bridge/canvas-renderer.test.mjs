import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import crypto from 'node:crypto';
import { canvasPage, canvasLibrary, canvasChunk } from './canvas-page.mjs';
import { sources } from './fixtures/canvas-show.mjs';
import { learnCanvasOrigin, phoneProjection } from './rich-content.mjs';
const root = new URL('./renderer/', import.meta.url);
test('pinned shell-free renderer has only renderer inputs and every shipped asset matches SHA256', () => {
  const manifest = JSON.parse(fs.readFileSync(new URL('manifest.json', root)));
  assert.match(manifest.canvasCommit, /^[a-f0-9]{40}$/);
  assert.equal(manifest.buildRecipeSHA256, crypto.createHash('sha256').update(fs.readFileSync(new URL('build.mjs', root))).digest('hex'));
  assert.ok(manifest.transforms.includes('HTML host intrinsic sizing; sandbox/bridge unchanged'));
  const inputs = Object.keys(manifest.inputs).join('\n');
  assert.ok(inputs.includes('OpenUIView.tsx') && inputs.includes('HtmlView.tsx'));
  for (const forbidden of ['src/ui/app.tsx', 'src/ui/transport.ts', 'src/ui/drafts.ts', 'dist/opencode/web/app.js', 'src/openchamber/', 'node_modules/mermaid/']) assert.ok(!inputs.includes(forbidden), forbidden);
  for (const [name, hash] of Object.entries(manifest.files)) assert.equal(crypto.createHash('sha256').update(fs.readFileSync(new URL('assets/' + name, root))).digest('hex'), hash);
  for (const [name, hash] of Object.entries(manifest.libraries)) assert.equal(crypto.createHash('sha256').update(fs.readFileSync(new URL('assets/lib/' + name + '.js', root))).digest('hex'), hash);
  const bundle = fs.readFileSync(new URL('assets/renderer.js', root), 'utf8');
  // Upstream HTML bridge includes a sandbox storage polyfill; shared Zod schemas include field *names*, not credentials.
  for (const forbidden of ['/api/snapshot', '/api/pin', 'Saved views', 'Open in browser', 'preferredSurface', 'viewerKey']) assert.ok(!bundle.includes(forbidden), forbidden);
  assert.ok(bundle.length < 5 * 1024 * 1024);
});
test('page has only one revision, strict CSP and lazy allowlisted HTML libraries', () => {
  const page = canvasPage({ format: 'html', source: sources.html, viewId: 'fixture', revision: 1, title: 'Fixture', disabled: false });
  for (const forbidden of ['/api/snapshot', '/api/pin', 'Saved views', 'viewerKey', 'panelID']) assert.ok(!page.includes(forbidden), forbidden);
  const bootstrap = page.split('window.canvasRevision=')[1].split(';</script>')[0];
  assert.ok(!bootstrap.includes('sessionKey'));
  assert.ok(page.includes("connect-src 'none'") && page.includes("frame-src 'none'"));
  assert.ok(page.includes('allow-scripts'));
  assert.throws(() => canvasLibrary('mermaid', sources.html, 'html'));
  assert.throws(() => canvasLibrary('../renderer', 'canvas:lib/../renderer', 'html'));
  assert.throws(() => canvasLibrary('mermaid', 'canvas:lib/mermaid', 'openui'));
  assert.ok(canvasLibrary('mermaid', '<script src="canvas:lib/mermaid"></script>', 'html').length > 5000000);
});
test('runtime connect origin strips prose paths; disconnected Canvas-like prose fails closed', () => {
  learnCanvasOrigin('https://synthetic-viewer.invalid:9444');
  assert.ok(!JSON.stringify(phoneProjection({ text: '[Details](https://synthetic-viewer.invalid:9444/arbitrary)' })).includes('synthetic-viewer.invalid'));
  assert.ok(!JSON.stringify(phoneProjection({ text: 'Open Canvas at https://unknown.fixture.invalid/no-key' })).includes('unknown.fixture.invalid'));
  assert.equal(phoneProjection('Guide: https://example.org/guide'), 'Guide: https://example.org/guide');
});
test('review regression: unlearned private hosts fail closed but ordinary HTTPS passes', () => {
  for (const raw of ['https://host-16.example.ts.net/path', 'http://127.0.0.1:8877/path', 'http://[::1]:8877/path', 'https://canvas-anything.invalid/path']) assert.ok(!phoneProjection(raw).includes('://'), raw);
  assert.equal(phoneProjection('[Apple](https://apple.com/iphone)'), '[Apple](https://apple.com/iphone)');
  assert.equal(phoneProjection('Canvas created. See [Apple docs](https://apple.com/iphone).'), 'Canvas created. See [Apple docs](https://apple.com/iphone).');
});
test('review regression: learned host is denied on every port', () => {
  learnCanvasOrigin('https://viewer-opaque.fixture.invalid:9000');
  assert.ok(!phoneProjection('https://viewer-opaque.fixture.invalid:9001/path').includes('viewer-opaque'));
});
test('review regression: wrapped and Markdown-truncated key values are removed', () => {
  for (const raw of ['[Open](https://host-16.example.ts.net/#key=\nSYNTHETIC_WRAPPED_TOKEN&view=1)', '[Open](https://opaque.fixture.invalid/#key=)\n`SYNTHETIC_WRAPPED_TOKEN`', '#key=\n[SYNTHETIC_WRAPPED_TOKEN](ignored)', 'key=\n`SYNTHETIC_WRAPPED_TOKEN`', 'https://opaque.fixture.invalid/#%6bey=\nSYNTHETIC_WRAPPED_TOKEN']) assert.ok(!phoneProjection(raw).includes('SYNTHETIC_WRAPPED_TOKEN'));
});
test('bounded resource chunks preserve UTF8 and reject malformed offsets', () => {
  const source = '🙂'.repeat(70000), chunks = []; let offset = 0;
  while (true) { const part = canvasChunk(source, offset); chunks.push(Buffer.from(part.chunk, 'base64')); if (part.nextOffset === null) break; offset = part.nextOffset; }
  assert.equal(Buffer.concat(chunks).toString('utf8'), source);
  for (const offset of [-1, 0.1, '1', 999999999]) assert.throws(() => canvasChunk(source, offset));
});
