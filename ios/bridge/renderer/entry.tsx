// Shell-free entry: only a single revision, never the Canvas viewer application/transport.
import React from 'react';
import { createRoot } from 'react-dom/client';
import { OpenUIView } from 'canvas/OpenUIView';
import { HtmlView } from 'canvas/HtmlView';

declare global { interface Window { canvasRevision: any; canvasSetDisabled: (v: boolean) => void; canvasLibraryResult: (name: string, source: string) => void; canvasLibraryFailed: () => void; webkit: any } }
const revision = window.canvasRevision;
const pending = new Map<string, { resolve: (s: string) => void; reject: (e: Error) => void }>();
const post = (value: unknown) => window.webkit.messageHandlers.canvasPanel.postMessage(value);
window.canvasLibraryResult = (name, source) => { pending.get(name)?.resolve(source); pending.delete(name); };
window.canvasLibraryFailed = () => { for (const p of pending.values()) p.reject(new Error('Library unavailable')); pending.clear(); };
function loadLibrary(name: string): Promise<string> {
  return new Promise((resolve, reject) => { pending.set(name, { resolve, reject }); post({ type: 'library', name }); });
}
const root = createRoot(document.getElementById('root')!);
let disabled = revision.disabled;
let gestureAt = 0;
for (const type of ['pointerdown', 'keydown']) document.addEventListener(type, event => { if (event.isTrusted) gestureAt = performance.now(); }, true);
function render() {
  const common = { source: revision.source, appearance: 'dark' as const, disabled, initialState: null, onState: () => {},
    onSend: async (action: string, data: unknown) => {
      // HtmlView applies the upstream frame/activation check; OpenUI events must originate in our own trusted gesture.
      if (!disabled && (revision.format === 'html' || (gestureAt > 0 && performance.now() - gestureAt < 1500))) post({ type: 'send', action, data });
    },
    onOpenUrl: (url: string) => post({ type: 'link', url }), onErrors: (_: string[]) => {} };
  root.render(revision.format === 'openui' ? <OpenUIView {...common}/> : <HtmlView {...common} view={{ id: revision.viewId, revision: revision.revision, title: revision.title }} frameMode="srcdoc" loadLibrary={loadLibrary}/>);
}
window.canvasSetDisabled = value => { disabled = value; render(); };
render();
new ResizeObserver(() => {
  const height = Math.ceil(document.getElementById('root')!.getBoundingClientRect().height);
  if (height > 0) post({ type: 'height', height: height + 4 });
}).observe(document.getElementById('root')!);
