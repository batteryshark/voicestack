"""Main-card fixture wiring: reuse History's blocks, not speech-cleaned Markdown."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent


class MainLogMarkdownTests(unittest.TestCase):
    def test_main_card_uses_projected_blocks_and_keeps_caption_and_details_contract(self):
        source = (ROOT/'native/FloatingVoiceApp.swift').read_text()
        bubble = source.split('struct VoiceLogBubble: View {', 1)[1].split('struct CallAudioSettings:', 1)[0]
        self.assertIn('MarkdownView(blocks: turn.spokenBlocks)', bubble)
        self.assertNotIn('MarkdownView(text: turn.spoken)', bubble)
        self.assertIn('.accessibilityLabel(turn.spoken).accessibilityIdentifier(captionID)', bubble)
        self.assertIn('MarkdownView(text: turn.details)', bubble)
        self.assertIn('Text(turn.displayLabel)', bubble)

    def test_history_renderer_still_uses_the_same_parser_and_grid(self):
        source = (ROOT/'native/FloatingVoiceApp.swift').read_text()
        self.assertIn('init(text: String) { blocks = BlockMarkdown.renderBlocks(text) }', source)
        self.assertIn('init(blocks: [MarkdownBlock]) { self.blocks = blocks }', source)
        self.assertIn('case .table(let rows):', source)
        self.assertIn('Grid(alignment: .topLeading)', source)


if __name__ == '__main__':
    unittest.main()
