from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from test_mac_voice_parity import block

ROOT = Path(__file__).resolve().parent.parent


class SessionPagingWiringTests(unittest.TestCase):
    def test_picker_lazy_footer_refresh_and_retry_use_paged_state(self):
        source = (ROOT/'native/FloatingVoiceApp.swift').read_text()
        picker = block(source, r'struct SessionPickerView:')
        self.assertIn('if model.sessionPaging.hasMore', picker)
        self.assertIn('.task { await model.loadSessions() }', picker)
        self.assertIn('.id(model.sessionPaging.nextCursor)', picker)
        self.assertIn('.refreshable { await model.loadSessions(reset: true) }', picker)
        self.assertIn('Retry loading sessions', picker)
        self.assertNotIn('.prefix(', picker)

    def test_model_fences_replaced_backends_and_paging_requests(self):
        source = (ROOT/'native/FloatingVoiceApp.swift').read_text()
        loader = block(source, r'func loadSessions\(')
        self.assertIn('sessionPaging.begin()', loader)
        self.assertIn('backend.listSessionsPage(cursor: request.cursor)', loader)
        self.assertEqual(loader.count('guard self.backend === backend'), 2)
        self.assertIn('sessionPaging.complete(request, page: page)', loader)
        self.assertIn('sessionPaging.fail(request, message:', loader)

    def test_swift_parity_wrapper_uses_python_default_without_worktree_override(self):
        wrapper = (ROOT/'app/Tests/FloatingVoiceCoreTests/MacVoiceParityTests.swift').read_text()
        self.assertIn('native/test_mac_voice_parity.py', wrapper)
        self.assertNotIn('process.environment =', wrapper)
        self.assertNotIn('Skip', wrapper)

    def test_every_backend_assignment_uses_one_paging_reset_helper(self):
        source = (ROOT/'native/FloatingVoiceApp.swift').read_text()
        helper = block(source, r'private func replaceBackend\(')
        self.assertIn('private(set) var backend:', source)
        self.assertLess(helper.index('sessionPaging.reset()'), helper.index('self.backend = backend'))
        self.assertNotIn('await ', helper)
        # Exclude local declarations; any remaining property assignment outside
        # the helper is a regression, including an unqualified/inline assignment.
        for path in sorted((ROOT/'native').glob('*.swift')):
            contents = path.read_text()
            if path.name == 'FloatingVoiceApp.swift': contents = contents.replace(helper, '')
            if path.name == 'RichContentViews.swift':
                # BoundContentView initializes its OWN immutable backend field;
                # these two constructor bodies do not write PhoneModel.backend.
                view = block(contents, r'struct BoundContentView:')
                self.assertIn('let backend: RemoteSessionBackend', view)
                for declaration in [r'init\(backend:', r'init\(fixtureDocument:']:
                    contents = contents.replace(block(view, declaration), '')
            remaining = re.sub(r'\b(?:let|var) backend\s*=', '', contents)
            self.assertEqual(re.findall(r'\bbackend\s*=(?!=)', remaining), [], str(path))
        for declaration in [r'func prepare\(', r'func joinInvitation\(']:
            self.assertIn('replaceBackend(backend)', block(source, declaration))

    def test_fixture_installation_is_simulator_debug_only_and_delegates_reset(self):
        source = (ROOT/'native/FloatingVoiceApp.swift').read_text()
        signature = 'func installFixtureBackend('
        start = source.index(signature)
        self.assertGreater(source.rfind('#if DEBUG && targetEnvironment(simulator)', 0, start), source.rfind('#endif', 0, start))
        self.assertEqual(block(source, r'func installFixtureBackend\(').strip(), 'replaceBackend(backend)')
        for name in ['PolishPreview.swift', 'CanvasShowFixture.swift']:
            fixture = (ROOT/'native'/name).read_text()
            self.assertTrue(fixture.startswith('#if DEBUG && targetEnvironment(simulator)'))
            self.assertIn('model.installFixtureBackend(backend)', fixture)
            self.assertNotRegex(fixture, r'\bmodel\.backend\s*=(?!=)')

    def test_actual_native_loader_recovers_from_incoming_replacement_then_old_success_or_error(self):
        source = (ROOT/'native/FloatingVoiceApp.swift').read_text()
        helper = block(source, r'private func replaceBackend\(')
        loader = block(source, r'func loadSessions\(')
        summary = block((ROOT/'app/Sources/FloatingVoiceCore/SessionBackend.swift').read_text(), r'public struct SessionSummary:')
        # Compile the exact native method bodies with deterministic in-memory
        # backends. No UIKit, endpoint, credentials, call provider or phone.
        harness = '''import Foundation
public struct SessionSummary: Equatable, Sendable { SUMMARY }
@MainActor final class RemoteSessionBackend {
    var pending: CheckedContinuation<SessionPage, Error>?
    var cursors: [String?] = []
    func listSessionsPage(cursor: String?) async throws -> SessionPage {
        cursors.append(cursor)
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finish(_ result: Result<SessionPage, Error>) {
        let completion = pending!; pending = nil; completion.resume(with: result)
    }
}
@MainActor final class PhoneModel {
    var backend: RemoteSessionBackend?
    var sessionPaging = SessionPaging()
    func replaceBackend(_ backend: RemoteSessionBackend?) { HELPER }
    func loadSessions(reset: Bool = false) async { LOADER }
}
enum FixtureError: Error { case oldFailure }
@main struct Regression {
    @MainActor static func waitForPage(_ backend: RemoteSessionBackend) async {
        let deadline = Date().addingTimeInterval(3)
        while backend.pending == nil && Date() < deadline { await Task.yield() }
        precondition(backend.pending != nil, "replacement page did not start")
    }
    @MainActor static func scenario(oldFails: Bool, replacementFinishesFirst: Bool) async {
        let model = PhoneModel(), old = RemoteSessionBackend(), incoming = RemoteSessionBackend()
        model.replaceBackend(old)
        let initial = model.sessionPaging.begin()!
        model.sessionPaging.complete(initial, page: SessionPage(sessions: [SessionSummary(id: "ses_prior", title: "Prior", updated: 0)], nextCursor: "older"))
        let oldRequest = Task { await model.loadSessions() }
        await waitForPage(old)
        precondition(model.sessionPaging.loading && old.cursors == ["older"])
        // This is the same helper now called by joinInvitation and prepare.
        model.replaceBackend(incoming)
        precondition(!model.sessionPaging.loading && model.sessionPaging.sessions.isEmpty && model.sessionPaging.error == nil)
        let newRequest = Task { await model.loadSessions() }
        await waitForPage(incoming)
        precondition(incoming.cursors.count == 1 && incoming.cursors[0] == nil, "replacement retained old pagination cursor")
        let fresh = SessionPage(sessions: [SessionSummary(id: "ses_new", title: "New", updated: 2)])
        if replacementFinishesFirst { incoming.finish(.success(fresh)); await newRequest.value }
        old.finish(oldFails ? .failure(FixtureError.oldFailure) : .success(SessionPage(sessions: [SessionSummary(id: "ses_stale", title: "Stale", updated: 1)])))
        await oldRequest.value
        if !replacementFinishesFirst {
            precondition(model.sessionPaging.loading && model.sessionPaging.sessions.isEmpty && model.sessionPaging.error == nil,
                         "retired request cleared or poisoned the new owner")
            incoming.finish(.success(fresh)); await newRequest.value
        }
        precondition(model.sessionPaging.sessions == fresh.sessions && !model.sessionPaging.loading && model.sessionPaging.error == nil,
                     "incoming backend left picker stuck or published stale rows/error")
    }
    static func main() async {
        for oldFails in [false, true] {
            for replacementFinishesFirst in [false, true] {
                await scenario(oldFails: oldFails, replacementFinishesFirst: replacementFinishesFirst)
            }
        }
        print("4 native backend replacement success/error ownership races passed")
    }
}
'''.replace('SUMMARY', summary).replace('HELPER', helper).replace('LOADER', loader)
        with tempfile.TemporaryDirectory(prefix='fv-picker-replacement-') as folder:
            swift = Path(folder)/'Regression.swift'; swift.write_text(harness)
            binary = Path(folder)/'regression'
            compiled = subprocess.run(['swiftc', '-parse-as-library', str(ROOT/'app/Sources/FloatingVoiceCore/SessionPaging.swift'), str(swift), '-o', str(binary)], capture_output=True, text=True, timeout=90)
            self.assertEqual(compiled.returncode, 0, compiled.stdout+compiled.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            self.assertIn('4 native backend replacement', result.stdout)


if __name__ == '__main__': unittest.main()
