// Private callback seam in the owned 2.0.32 runtime only. Not an agent tool/API.
let observer;
export function observeRuntime(callback) {
  if (observer) throw new Error('owned_runtime_already_observed');
  observer = callback;
  return () => { if (observer === callback) observer = undefined; };
}
export function runtimeHook(type, data) { observer?.(type, data); }
