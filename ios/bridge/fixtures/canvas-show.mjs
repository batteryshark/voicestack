// Synthetic only. Never derived from a live Canvas revision, key, or origin.
export const sources = {
  openui: 'root = Stack([heading, text, buttons])\nheading = TextContent("Release decision", "large-heavy")\ntext = TextContent("OpenUI panel · synthetic fixture. Choose a path to send through the bridge.")\nbuttons = Buttons([Button("Review first", @ToAssistant("Review first"), "primary"), Button("Revise plan", @ToAssistant("Revise plan"), "secondary")])',
  html: '<!doctype html><html><head><style>body{padding:18px;font:17px system-ui}h2{color:#80c9ff}button{background:#2573bb;color:white;border:0;border-radius:12px;padding:16px;font:inherit}p{line-height:1.5}</style></head><body><h2>HTML decision panel</h2><p>A sandboxed HTML view, rendered here in the conversation.</p><button data-canvas-action="Review first">Review first</button><p>No browser handoff. No network access.</p></body></html>'
};
export const viewIds = { openui: '11111111-1111-4111-8111-111111111111', html: '22222222-2222-4222-8222-222222222222' };
export function showRecord(format) {
  return { id: 'msg_' + format, type: 'assistant', content: [{ type: 'text', text: 'Here is the ' + format + ' decision panel.' }, { type: 'tool', id: 'tool_' + format, name: 'canvas_show', executed: false, state: {
    status: 'completed', input: { title: 'Decision panel', summary: 'Synthetic fixture', format, source: sources[format] },
    metadata: { title: 'Decision panel', viewId: viewIds[format], revision: 1, truncated: false },
    content: [{ type: 'text', text: 'View ' + viewIds[format] + '\nRevision 1\nhttps://canvas.fixture.invalid/#key=FAKE_ONLY&view=' + viewIds[format] }]
  } }] };
}
