// Small private modification of MIT-licensed @opencode/core + schema 2.0.32.
// Originals and their notices stay in node_modules; no upstream publication.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const directory = fileURLToPath(new URL('./', import.meta.url));
const core = path.join(directory, 'node_modules/@opencode/core');
if (JSON.parse(fs.readFileSync(path.join(core, 'package.json'))).version !== '2.0.32') throw new Error('runtime_version_mismatch');
if (JSON.parse(fs.readFileSync(path.join(core, '../schema/package.json'))).version !== '2.0.32') throw new Error('schema_version_mismatch');
const patches = [
  ['../../../schema/dist/session-event.js', [
    ['export const InstructionsUpdated =', `export const VoiceEnded = Event.durable({
    type: "session.voice.ended", ...options,
    schema: { ...Base, callID: Schema.String, operationID: Schema.String, ownerEpoch: Schema.String,
        text: Schema.Literal("[voice] ended") },
});
export const InstructionsUpdated =`],
    ['UsageRecorded, MessageContentUpdated);', 'UsageRecorded, MessageContentUpdated, VoiceEnded);'],
  ]],
  ['../../../schema/dist/session-message.js', [
    ['    /** The model-facing update text, frozen at emit time. */', '    historyOnly: Schema.Literal(true).pipe(optional),\n    /** The model-facing update text, frozen at emit time. */'],
  ]],
  ['instance-h7s7r6s9.js', [
    ['    "session.instructions.updated": (event) => {', `    "session.voice.ended": (event) => adapter.appendMessage(SessionMessage2.System.make({
      id: SessionMessage2.ID.fromEvent(event.id), type: "system", text: event.data.text,
      historyOnly: true, time: { created }
    })),
    "session.instructions.updated": (event) => {`],
  ]],
  ['instance-6btvgc07.js', [
    ['  yield* bus.project(SessionEvent2.InstructionsUpdated,', '  yield* bus.project(SessionEvent2.VoiceEnded, (event) => run(db, event));\n  yield* bus.project(SessionEvent2.InstructionsUpdated,'],
  ]],
  ['instance-xt4njr3s.js', [
    ['      return [Message.system(message.text)];', '      return message.historyOnly === true ? [] : [Message.system(message.text)];'],
  ]],
  ['instance-yp2x3t23.js', [
    ['    Deferred.doneUnsafe(execution.done, exit);', '    Deferred.doneUnsafe(execution.done, exit);\n    runtimeHook("execution-settled", { sessionID: key, active: executions.has(key) });'],
  ]],
  ['instance-71svxegq.js', [
    ['    const sessionID = first.session.id;', '    const sessionID = first.session.id;\n    runtimeHook("step-enter", { sessionID });'],
    ['        Completed: (outcome) => Effect.succeed(outcome.needsContinuation),',
      '        Completed: (outcome) => Effect.sync(() => {\n          runtimeHook("candidate", { sessionID, assistantMessageID, agent: loaded.agent.id, model: loaded.model.ref, needsContinuation: outcome.needsContinuation });\n          return outcome.needsContinuation;\n        }),'],
  ]],
  ['instance-xnn7a7ef.js', [
    ['    if (result.scope) {\n      yield* Scope.close(result.scope, Exit.void).pipe(Effect.forkIn(state.scope, { startImmediately: true }));',
      '    if (result.info) runtimeHook("job-settled", result.info);\n    if (result.scope) {\n      yield* Scope.close(result.scope, Exit.void).pipe(Effect.forkIn(state.scope, { startImmediately: true }));'],
    ['  const start = Effect.fnUntraced(function* (input) {',
      '  const start = Effect.fnUntraced(function* (input) {\n    runtimeHook("job-start", { id: input.id, recovery: input.recovery, metadata: input.metadata });'],
    ['    if (result.info && result.backgrounded)\n      yield* Deferred.succeed(result.backgrounded, result.info);',
      '    if (result.info) runtimeHook("job-background", result.info);\n    if (result.info && result.backgrounded)\n      yield* Deferred.succeed(result.backgrounded, result.info);'],
    ['    yield* persistBackground(next);\n    return next;',
      '    yield* persistBackground(next);\n    runtimeHook("job-background", next.info);\n    return next;'],
    ['    if (result.generation)\n      yield* consume(id, result.generation);\n    return result.info;',
      '    if (result.generation)\n      yield* consume(id, result.generation);\n    if (result.info) runtimeHook("job-settled", result.info);\n    return result.info;'],
    ['    yield* kv.remove(`${backgroundPrefix}${notificationID}`);',
      '    runtimeHook("notification-admitted", { notificationID });\n    yield* kv.remove(`${backgroundPrefix}${notificationID}`);'],
  ]],
];
// Validate every replacement before writing any file. A different distribution
// must be reviewed, not approximately matched or silently patched twice.
const writes = [];
for (const [file, replacements] of patches) {
  const target = path.join(core, 'dist/chunks', file);
  const original = fs.readFileSync(target, 'utf8');
  const hookImport = `import { runtimeHook } from ${JSON.stringify(path.relative(path.dirname(target), path.join(directory, 'direct-hooks.mjs')).replaceAll(path.sep, '/'))};\n`;
  const installed = original.startsWith(hookImport);
  let text = installed ? original.slice(hookImport.length) : original;
  for (const [before, after] of replacements) {
    if (installed && text.split(after).length === 2) continue;
    if (text.split(before).length !== 2) throw new Error(`private_patch_anchor_mismatch:${file}`);
    text = text.replace(before, after);
  }
  if (hookImport + text !== original) writes.push([target, hookImport + text]);
}
for (const [target, text] of writes) fs.writeFileSync(target, text);
console.log(JSON.stringify({ privateRuntimePatch: '2.0.32', filesWritten: writes.length }));
