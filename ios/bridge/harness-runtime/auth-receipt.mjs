// One finite observer of one captured native attempt. No credentials or journal.
// Native terminal attempts disappear after 60–90s; retain only their safe receipt.
export function observeAuthReceipt({ read, cancel, expires, changed = () => {}, terminal = () => {}, pollMs = 1000, maxMs = 635000 }) {
  const deadline = Math.min(Date.now() + maxMs, expires + 35000);
  let receipt = { status: 'pending' }, busy = true, known = true;
  const unavailable = reason => ({ status: 'receipt_unavailable', reason });
  const publish = value => { receipt = structuredClone(value); changed(); };
  const done = (async () => {
    try {
      for (;;) {
        const remaining = deadline - Date.now();
        if (remaining <= 0) { publish(unavailable('observation_deadline')); break; }
        const value = await read(Math.min(5000, remaining));
        publish(value);
        if (['complete', 'failed', 'expired'].includes(value.status)) { terminal(value.status); return; }
        if (value.status !== 'pending') break;
        await new Promise(resolve => setTimeout(resolve, Math.min(pollMs, Math.max(0, deadline - Date.now()))));
      }
    } catch { publish(unavailable('native_status_unavailable')); }
    // End only this native attempt, not the host or agent work. A missing receipt
    // is never relabelled success/failure/expiry. Failed cleanup stays unknown.
    try { await cancel(5000); known = (await read(5000)).status !== 'pending'; }
    catch { known = false; }
  })().finally(() => { if (receipt.status === 'receipt_unavailable') terminal('receipt_unavailable'); busy = false; changed(); });
  return { snapshot: () => structuredClone(receipt), work: () => ({ busy, known }), done };
}
