// Personal SOURCE build only. No install, download, shell, or source-tree writes.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import childProcess from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import vm from 'node:vm';
import { resourceRoot, sourceHashes, verifyResources, checkedPath } from './resources.mjs';
const here = path.dirname(fileURLToPath(import.meta.url));
const sha = b => crypto.createHash('sha256').update(b).digest('hex');
const lock = JSON.parse(fs.readFileSync(path.join(here, 'source-lock.json')));
const read = (root, rel, hash) => {
  const p = checkedPath(root + '/' + rel, false);
  const b = fs.readFileSync(p);
  if (sha(b) !== hash) throw Error('Pinned input mismatch: ' + rel);
  return b;
};
const out = resourceRoot(true); // Validate RAW spelling, ancestors, ownership, freshness BEFORE mkdir.
const deps = process.env.FV_CANVAS_DEPENDENCIES;
if (!deps || !path.isAbsolute(deps)) throw Error('FV_CANVAS_DEPENDENCIES must name an audited dependency root');
checkedPath(deps, false);
if (process.version !== lock.toolchain.node) throw Error('Node pin mismatch');
const lib = read(deps, 'node_modules/esbuild/lib/main.js', lock.toolchain.esbuildJS);
const platform = `${process.platform}-${process.arch}`;
const binaryRel = `node_modules/@esbuild/${platform}/bin/esbuild`;
const binaryHash = lock.toolchain.binaries[platform];
if (!binaryHash) throw Error('Platform compiler hash not admitted; audit and extend lock first');
read(deps, binaryRel, binaryHash);
const binary = path.join(deps, binaryRel);
// Exactly one native service; all other subprocess APIs fail closed.
let child, count = 0;
let childClosedPromise, childCloseObserved, childError;
let stopInProgress = false, stopWasLive = false, ownedStopRequested = false;
const record = (event, detail = {}) => fs.appendFileSync(path.join(out, 'build-events.jsonl'), JSON.stringify({ event, ...detail })+'\n');
const spawn = childProcess.spawn;
childProcess.spawn = (command, args, options) => {
  if (command !== binary || JSON.stringify(args) !== JSON.stringify(['--service=0.25.12', '--ping']) || ++count !== 1)
    throw Error('Subprocess refused');
  child = spawn(command, args, { ...options, env: { PATH: '/usr/bin:/bin', HOME: process.env.HOME, TMPDIR: process.env.TMPDIR, GOMAXPROCS: '1' } });
  // Observe immediately, before returning the child to esbuild (which unrefs it).
  childClosedPromise = new Promise(resolve => child.once('close', (code, signal) => {
    childCloseObserved = { code, signal };
    record('child-close', childCloseObserved);
    resolve(childCloseObserved);
  }));
  child.on('error', error => { childError = error; record('child-error'); });
  const kill = child.kill;
  child.kill = function(signal = 'SIGTERM') {
    const eligible = stopInProgress && stopWasLive && !childCloseObserved && !childError &&
      this.exitCode === null && this.signalCode === null && !this.killed && signal === 'SIGTERM';
    const requested = kill.call(this, signal);
    if (eligible && requested === true) ownedStopRequested = true;
    record('child-kill-request', { signal, ownedStopRequested });
    return requested;
  };
  record('child-spawn', { pid: child.pid });
  return child;
};
async function stopAndConfirm(compiler, timeoutMS = 5000) {
  stopWasLive = child.exitCode === null && child.signalCode === null && !child.killed && !childCloseObserved;
  let timer;
  try {
    // A referenced deadline keeps the event loop alive even after esbuild unrefs
    // its child and pipes. It bounds BOTH stop resolution and observed close.
    const deadline = new Promise((_, reject) => { timer = setTimeout(() => reject(Error('Compiler child close timeout')), timeoutMS); });
    stopInProgress = true;
    record('child-stop-begin', { previouslyLive: stopWasLive, deadlineMS: timeoutMS });
    await Promise.race([Promise.resolve().then(() => compiler.stop()), deadline]);
    const closed = await Promise.race([childClosedPromise, deadline]);
    if (childError) throw childError;
    if (!((closed.code === 0 && closed.signal === null) ||
          (stopWasLive && ownedStopRequested && closed.code === null && closed.signal === 'SIGTERM')))
      throw Error('Unexpected compiler child termination');
    if (count !== 1) throw Error('Unexpected child count');
    record('child-lifecycle-confirmed', { ...closed, ownedStopRequested });
    return closed;
  } finally { stopInProgress = false; clearTimeout(timer); }
}
for (const name of ['exec','execSync','execFile','execFileSync','spawnSync','fork']) childProcess[name] = () => { throw Error('Subprocess refused'); };
syncBuiltinESMExports();
process.env.ESBUILD_BINARY_PATH = binary;
process.env.ESBUILD_WORKER_THREADS = '0';
fs.mkdirSync(out, { mode: 0o700 }); // No recursive mkdir, overwrite, or deletion. Incomplete until manifest published last.
fs.writeFileSync(path.join(out, 'build-events.jsonl'), '', { flag:'wx' });
record('output-reserved');
const work = path.join(out, '.work'); fs.mkdirSync(work);
const put = (rel, bytes) => {
  const p = path.join(work, rel); fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, bytes, { flag: 'wx' });
};
try {
  for (const [rel, hash] of Object.entries(lock.inputs)) {
    const local = rel.startsWith('node_modules/') ? deps : here;
    put(rel, read(local, rel, hash));
  }
  for (const [rel, hash] of Object.entries(lock.metadata)) put(rel, read(deps, rel, hash));
  put('node_modules/esbuild/lib/main.js', lib);
  record('inputs-materialized', { contentInputs:Object.keys(lock.inputs).length, metadataInputs:Object.keys(lock.metadata).length });
  // Library artifacts are external pinned npm inputs, copied ONLY into ignored personal output.
  fs.mkdirSync(path.join(out, 'lib'));
  for (const [name, pin] of Object.entries(lock.libraries)) fs.writeFileSync(path.join(out, 'lib', name+'.js'), read(deps, pin.path, pin.sha256), { flag: 'wx' });
  const transforms = [];
  function replaceOnce(source, anchor, replacement, label) {
    if (source.split(anchor).length !== 2) throw Error('Transform anchor count: ' + label);
    const output = source.replace(anchor, replacement);
    transforms.push({ label, before: sha(source), after: sha(output), anchor, replacement, occurrences: 1 });
    return output;
  }
  const compiler = await import(pathToFileURL(path.join(work, 'node_modules/esbuild/lib/main.js')));
  const result = await compiler.build({ absWorkingDir: work, entryPoints: ['entry.tsx'], outfile: path.join(out, 'renderer.js'),
    bundle: true, minify: true, metafile: true, platform: 'browser', format: 'iife', target: 'es2022', jsx: 'automatic',
    nodePaths: [path.join(work, 'node_modules')], define: { 'process.env.NODE_ENV': '"production"' },
    loader: { '.woff':'dataurl', '.woff2':'dataurl', '.ttf':'dataurl', '.otf':'dataurl', '.png':'dataurl', '.svg':'dataurl', '.gif':'dataurl' },
    plugins: [{ name: 'pinned-source', setup(b) {
      b.onResolve({ filter: /^canvas\// }, args => {
        const map = { 'canvas/OpenUIView':'src/ui/openui/OpenUIView.tsx', 'canvas/HtmlView':'src/ui/html/HtmlView.tsx' };
        if (!map[args.path]) throw Error('Unknown Canvas import');
        return { path: path.join(work, map[args.path]) };
      });
      b.onLoad({ filter: /./ }, args => {
        const rel = path.relative(work, args.path).split(path.sep).join('/');
        if (!lock.inputs[rel]) throw Error('Unadmitted bundler input: ' + rel);
        if (sha(fs.readFileSync(args.path)) !== lock.inputs[rel]) throw Error('Loaded input hash mismatch: ' + rel);
        if (rel === 'src/ui/html/HtmlView.tsx') {
          let s = fs.readFileSync(args.path, 'utf8');
          s = replaceOnce(s, 'const MIN_HEIGHT = 240;', 'const MIN_HEIGHT = 1;', 'HTML minimum');
          s = replaceOnce(s, 'Math.max(MIN_HEIGHT, Math.round(viewport * 0.85))', 'Math.max(MIN_HEIGHT, contentHeight)', 'HTML intrinsic sizing');
          return { contents:s, loader:'tsx', resolveDir:path.dirname(args.path) };
        }
        if (rel === 'node_modules/@openuidev/react-ui/dist/genui-lib/index.mjs') {
          const s = fs.readFileSync(args.path, 'utf8');
          for (const a of ['\nconst ThemeContext = createContext({','\nconst defaultLightTheme = '])
            if (s.split(a).length !== 2) throw Error('Theme anchor count');
          const contents = s+'\nexport { ThemeContext as __canvasThemeContext, defaultLightTheme as __canvasLightTheme };\n';
          transforms.push({ label:'OpenUI theme exports', before:sha(s), after:sha(contents), occurrences:1,
            anchors:['\nconst ThemeContext = createContext({','\nconst defaultLightTheme = '], anchorCounts:[1,1] });
          return { contents, loader:'js', resolveDir:path.dirname(args.path) };
        }
      });
    } }] });
  record('compiler-build-complete');
  const inputs = Object.fromEntries(Object.keys(result.metafile.inputs).sort().map(rel => [rel, lock.inputs[rel]]));
  if (Object.keys(inputs).length !== 4008 || JSON.stringify(Object.keys(inputs)) !== JSON.stringify(Object.keys(lock.inputs).sort()) || Object.values(inputs).some(x => !x)) throw Error('Exact input closure changed');
  record('exact-metafile-verified', { inputs:4008 });
  const files = Object.fromEntries(['renderer.js','renderer.css',...Object.keys(lock.libraries).map(n => 'lib/'+n+'.js')].map(n => [n, sha(fs.readFileSync(path.join(out,n)))]));
  const outputs = Object.fromEntries(Object.entries(result.metafile.outputs).map(([p, v]) => [path.basename(p), { bytes:v.bytes, inputs:v.inputs, imports:v.imports }]));
  if (Object.values(outputs).some(o => o.imports.length)) throw Error('External output imports refused');
  const names = ['renderer.js','renderer.css','lib/tailwind.js','lib/chart.js.js','lib/d3.js','lib/mermaid.js'];
  if (JSON.stringify(Object.keys(files).sort()) !== JSON.stringify(names.sort())) throw Error('Resource set changed');
  for (const name of names) {
    const bytes = fs.readFileSync(checkedPath(out+'/'+name,false));
    if (!bytes.length || sha(bytes) !== files[name]) throw Error('Resource check failed: ' + name);
    if (name.endsWith('.js')) new vm.Script(bytes.toString('utf8'), { filename:name }); // Compile only, NEVER execute.
  }
  for (const [name,pin] of Object.entries(lock.libraries)) if (files['lib/'+name+'.js'] !== pin.sha256) throw Error('Library hash changed');
  for (const [name,pattern] of [['chart.js',/\.Chart\s*=/],['d3',/\.d3\s*=/],['mermaid',/mermaid\s*=/]])
    if (!pattern.test(fs.readFileSync(path.join(out,'lib',name+'.js'),'utf8'))) throw Error('Library global contract: ' + name);
  const entry = fs.readFileSync(path.join(work,'entry.tsx'),'utf8');
  for (const token of ['canvasLibraryResult','canvasLibraryFailed','canvasSetDisabled','canvasPanel'])
    if (!entry.includes(token) || !fs.readFileSync(path.join(out,'renderer.js'),'utf8').includes(token)) throw Error('Renderer API token: ' + token);
  const document = fs.readFileSync(path.join(work,'src/ui/html/document.ts'),'utf8');
  if (!document.includes('@custom-variant dark') || !document.includes('TAILWIND_DARK')) throw Error('Tailwind theme contract changed');
  if (transforms.length !== 3 || new Set(transforms.map(t => t.label)).size !== 3 || transforms.some(t => t.occurrences !== 1)) throw Error('Transform map incomplete');
  const metafile = { inputs:result.metafile.inputs, outputs };
  // Complete relative input/import/output map, no host path labels in public provenance.
  for (const n of Object.keys(metafile.inputs)) if (path.isAbsolute(n) || n.split('/').includes('..')) throw Error('Unsafe input label');
  if (JSON.stringify(metafile).includes(work) || JSON.stringify(metafile).includes(deps)) throw Error('Private metafile label');
  record('syntax-api-transforms-resources-verified', { syntaxScripts:5, transforms:3 });
  const sources = sourceHashes();
  const manifest = { kind:'personal-source-build-not-for-redistribution', toolchain:lock.toolchain, files, inputs, outputs, metafile, transforms, sources,
    checks:{ exactInputs:4008, syntaxCompiledNotExecuted:5, libraryGlobals:true, callbackTokens:true, tailwindTheme:true, resourcesVerifiedBeforePublication:true } };
  for (const [n,h] of Object.entries(sources)) if (sha(fs.readFileSync(path.join(here,n))) !== h) throw Error('Source changed during build');
  record('source-hashes-verified');
  await stopAndConfirm(compiler);
  // Publication is LAST, after closure, static/API/syntax/resource checks and child exit.
  fs.writeFileSync(path.join(out, 'manifest.json'), JSON.stringify(manifest,null,2)+'\n', { flag:'wx' });
  record('manifest-published');
  console.log(JSON.stringify({ ready:true, inputs:Object.keys(inputs).length, nativeChildren:count,
    nativeChild:{ pid:child.pid, executable:'esbuild', args:['--service=0.25.12','--ping'], exited:true }, outputs:files }));
} finally {
  if (child && child.exitCode === null && !child.killed) child.kill('SIGTERM');
}
