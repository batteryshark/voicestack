// Independent upstream/downstream clocks: a downstream heartbeat is NOT proof
// of upstream health. Injectable scheduler keeps deadline tests deterministic.
export function eventLifetime({ heartbeat, validate, close, clock = globalThis,
  heartbeatMs = 15000, staleMs = 75000, rotationMs = 240000 }) {
  let stopped = false, stale;
  const timers = [];
  const stop = () => {
    if (stopped) return;
    stopped = true;
    clock.clearTimeout(stale);
    for (const timer of timers) clock.clearInterval(timer);
  };
  const end = (initiator, reason, clean = false) => {
    if (stopped) return;
    stop(); close(initiator, reason, clean);
  };
  const bytes = () => {
    if (stopped) return;
    clock.clearTimeout(stale);
    stale = clock.setTimeout(() => end('watchdog', 'upstream_idle'), staleMs);
  };
  bytes();
  timers.push(clock.setInterval(() => heartbeat(), heartbeatMs));
  timers.push(clock.setInterval(() => {
    try { validate(); } catch { end('bridge', 'lease_invalid'); }
  }, 1000));
  timers.push(clock.setInterval(() => end('bridge', 'rotation', true), rotationMs));
  return { bytes, stop, end };
}
