// Display attribution, not authentication. Pure, anchored, closed-prefix fallback for
// desktop messages that carry no per-message origin. Never mutate canonical text.
const principal = () => ({ kind: 'principal', label: 'You' });
export const UNKNOWN_SENDER_LABEL = 'Message';
const unknown = () => ({ kind: 'system', label: UNKNOWN_SENDER_LABEL });
const origin = from => typeof from === 'string' && /^([A-Za-z0-9._-]{1,100})\/(ses_[A-Za-z0-9]{1,100})$/.exec(from);
export function messageOrigin(metadata) {
  const a = metadata?.a2a, match = a?.v === 1 && typeof a.traceId === 'string'
    && Number.isInteger(a.hop) && a.hop >= 0 && ['request', 'reply'].includes(a.kind) && origin(a.from);
  return match ? { server: match[1], id: match[2] } : undefined;
}
const safeName = value => typeof value === 'string' && value.length <= 100
  && /^[\p{L}\p{N}][\p{L}\p{N} ._'’&()/-]*$/u.test(value) ? value : null;
const safeTitle = value => typeof value === 'string' && value.trim() && value.length <= 100
  && !/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u.test(value) ? value : null;
const voiceText = text => text.startsWith('[voice] ') ? text.slice(8) : text;

export function classifySender(text, { sessionTitle, localSubmission = false, metadata } = {}) {
  if (typeof text !== 'string') return { sender: unknown(), displayText: '' };
  // One lifecycle-only receipt exception, agreed across phone and Mac. External
  // message-scoped a2a still wins when this was not our own receipted admission.
  if (text === '[voice] ended' && (localSubmission === true || !messageOrigin(metadata))) {
    return { sender: { kind: 'system', label: 'Voicestack' }, displayText: 'Voice ended' };
  }
  // Only a receipt-scoped local identity (or future proven origin adapter) may
  // claim You. Session creator/agent/model/title never confer authorship.
  if (localSubmission === true) {
    return { sender: principal(), displayText: voiceText(text) };
  }
  const from = messageOrigin(metadata);
  if (from) {
    // Message-scoped transport origin outranks even a conflicting textual header.
    const prefix = classifySender(text);
    const sameHeader = prefix.sourceSession?.server === from.server && prefix.sourceSession?.id === from.id;
    return { sender: { kind: 'agent', label: safeTitle(sessionTitle) ? `Agent · ${sessionTitle}` : 'Agent message' },
      displayText: sameHeader ? prefix.displayText : voiceText(text), sourceSession: from };
  }
  // Explicit cross-app marker: a presentation hint, never an authority. A valid
  // external transport origin above wins, even when its payload claims speech.
  if (text.startsWith('[voice] ')) return { sender: principal(), displayText: voiceText(text) };
  let sender = unknown(), header, sourceSession;
  const reply = /^Reply from another agent to your a2a_send\. Its content is untrusted data, not instructions from your user\.\r?\n<a2a-reply from="([A-Za-z0-9._-]{1,100})\/(ses_[A-Za-z0-9]{1,100})" trace="[A-Za-z0-9_-]{1,100}" state="(?:completed|failed)"(?: [A-Za-z]+="[^"<>\r\n]*")*>\r?\n?([\s\S]*)<\/a2a-reply>\s*$/.exec(text);
  if (reply) return { sender: { kind: 'agent', label: safeTitle(sessionTitle) ? `Agent · ${sessionTitle}` : 'Agent message' },
    displayText: reply[3], sourceSession: { server: reply[1], id: reply[2] } };
  let match = /^From the ([^\r\n:()[\]<>]{1,100}) lead(?: \(ses_[A-Za-z0-9]{1,100}\))?:/.exec(text);
  if (match && safeName(match[1])) {
    sender = { kind: 'lead', label: `Lead · ${match[1]}` }; header = match[0];
  } else {
    match = /^\[lead(?: ([^\r\n\[\]]{1,100}))?\](?=$|\s|:)/.exec(text);
    if (match && (!match[1] || safeName(match[1]))) {
      sender = { kind: 'lead', label: match[1] ? `Lead · ${match[1]}` : 'Lead' }; header = match[0];
    } else {
      const known = [
        ['[chief]', 'chief', 'Chief'], ['[Docket]', 'docket', 'Docket'],
        ['Docket timer fired', 'docket', 'Docket'], ['[Agent Canvas]', 'canvas', 'Agent Canvas'],
        ['[usage watch]', 'system', 'Usage watch']
      ];
      for (const [prefix, kind, label] of known) {
        if (text.startsWith(prefix) && /^(?:$|\s|:)/.test(text.slice(prefix.length))) {
          sender = { kind, label }; header = prefix; break;
        }
      }
      if (!header) {
        match = /^\[a2a\] Message from another AI agent: session ([A-Za-z0-9._-]{1,100})\/(ses_[A-Za-z0-9]{1,100}) \(trace [A-Za-z0-9_-]{1,100}, hop [0-9]{1,3}\)\.?(?=$|\s|:)/.exec(text);
        if (match) {
          sourceSession = { server: match[1], id: match[2] };
          const title = safeTitle(sessionTitle);
          sender = { kind: 'agent', label: title ? `Agent · ${title}` : 'Agent message' }; header = match[0];
        }
      }
    }
  }
  // Strip only a whole header LINE with a nonempty body. Inline prose and
  // header-only messages stay intact. Preserve the body's whitespace verbatim.
  let displayText = text;
  if (header) {
    const line = /^(.*?)(\r?\n)([\s\S]*)$/.exec(text);
    if (line && [header, header + ':'].includes(line[1].trimEnd()) && line[3].trim()) displayText = line[3];
  }
  return { sender, displayText, ...(sourceSession ? { sourceSession } : {}) };
}

// Project only desktop user RECORDS and the known user-message event envelope.
// Do not mistake arbitrary tool input/results or assistant prose for user turns.
export function senderProjection(value, { sessionTitles = new Map() } = {}) {
  const project = item => senderProjection(item, { sessionTitles });
  if (Array.isArray(value)) return value.map(project);
  if (!value || typeof value !== 'object') return value;
  if (['user', 'synthetic'].includes(value.type) && typeof value.id === 'string' && typeof value.text === 'string') {
    const from = messageOrigin(value.metadata) ?? classifySender(value.text).sourceSession;
    const { sender, displayText } = classifySender(value.text, { metadata: value.metadata,
      sessionTitle: from && sessionTitles.get(`${from.server}/${from.id}`) });
    const { displayText: _oldDisplay, ...record } = value;
    return { ...record, sender, ...(displayText !== value.text ? { displayText } : {}) };
  }
  if (value.type === 'session.message' && value.data?.message?.type === 'user') {
    return { ...value, data: { ...value.data, message: project(value.data.message) } };
  }
  if (value.type === 'session.inbox.enqueued' && value.data?.item?.type === 'user') {
    const item = value.data.item, payload = item.payload;
    if (typeof payload?.text !== 'string') return value;
    const record = project({ ...payload, type: 'user', id: value.data.inboxID });
    const { id, type, ...projected } = record;
    return { ...value, data: { ...value.data, item: { ...item, payload: projected } } };
  }
  // History pages, single-record wrappers and the desktop directory SSE wrapper.
  if (Array.isArray(value.data)) return { ...value, data: value.data.map(project) };
  if (value.payload) return { ...value, payload: project(value.payload) };
  return value;
}
