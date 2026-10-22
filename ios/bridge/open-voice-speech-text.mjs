// Final-text subset port of FloatingVoiceCore/SpeechText.swift. Never selects
// tools/reasoning/history or infers finality/causal lineage from timestamps.
const check = v => { if (!v) throw new Error('invalid_speech_text'); };
export function cleanSpeech(text) {
  check(typeof text === 'string' && text.length <= 32000 && [...text].length <= 16000 && !/[\uD800-\uDFFF]/u.test(text));
  return text
    .replace(/^[ \t]*(`{3,})[^\n]*\n[\s\S]*?(?:^[ \t]*\1`*[ \t]*(?:\n|(?![\s\S]))|(?![\s\S]))|^[ \t]*(~{3,})[^\n]*\n[\s\S]*?(?:^[ \t]*\2~*[ \t]*(?:\n|(?![\s\S]))|(?![\s\S]))|```[\s\S]*?(?:```|(?![\s\S]))/gm, ' ')
    .replace(/!\[[^\]]*\]\([^)]*\)/g, ' ').replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/https?:\/\/\S+/g, 'the linked page').replace(/`([^`]+)`/g, '$1')
    .replace(/^\s*[#>*-]+\s*/gm, '').replace(/[*_~]/g, '').replace(/\s+/g, ' ').trim();
}
// The caller supplies ONLY causally verified final assistant text. This module
// deliberately has no message-schema parser/finality guess or harness lookup.
export function speechSegments(finalText, maxLength = 32000) {
  const clean = cleanSpeech(finalText); check(clean.length <= maxLength);
  const result = []; let remaining = clean;
  while (remaining.length) {
    let cut = -1;
    for (const m of remaining.matchAll(/[.!?](?=\s|$)/g)) {
      if (m.index < 35 || m.index >= 260) continue;
      const end = m.index + 1, head = remaining.slice(Math.max(0, end - 12), end);
      if (/(?:^|[\s(])(?:e\.g|i\.e|etc|vs|cf|approx|Mr|Mrs|Ms|Dr|St|No)\.$/i.test(head)) continue;
      cut = end; break;
    }
    if (cut < 0 && remaining.length > 260) { const space = remaining.lastIndexOf(' ', 240); cut = space > 0 ? space : 240; }
    if (cut < 0) cut = remaining.length;
    if (cut < remaining.length && /[\uD800-\uDBFF]/.test(remaining[cut - 1])) cut--;
    const segment = remaining.slice(0, cut).trim(); if (segment) result.push(segment);
    remaining = remaining.slice(cut).trimStart();
  }
  return result;
}
