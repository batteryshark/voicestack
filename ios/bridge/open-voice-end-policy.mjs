// Private normal-assembly provenance, never a wire/configuration field.
const policies = new WeakMap();
export function installEndPolicy(control, verify, append) {
  if (policies.has(control) || control.endNote !== undefined) throw new Error('end_policy_refused');
  const callback = payload => append(payload);
  policies.set(control, { callback, verify });
  control.endNote = callback;
}
export const trustedEndPolicy = control => policies.get(control)?.callback === control.endNote && control.endNote !== undefined;
export const futureEndCall = (control, call) => trustedEndPolicy(control) && call.end_note_version === 1;
export const inertEndAssembly = (control, call) => !Object.hasOwn(call, 'end_note_version')
  && (control.endNote === undefined || trustedEndPolicy(control));
export const verifyTerminalEnd = (control, payload) => policies.get(control).verify(payload);
