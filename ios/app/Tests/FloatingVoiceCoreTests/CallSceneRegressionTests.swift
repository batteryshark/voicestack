import Foundation
import Testing
@testable import FloatingVoiceCore

@MainActor private final class SceneProbe {
    var foreground = false, protectedDataAvailable = false, paired = true
    var lease: TargetLease?
    var typed = "typed before lock"
    var drafts: [BoundDraft] = []
    var order: [String] = []
    let voice = NativeVoiceLifecycle()
    func retain(_ draft: BoundDraft) { drafts.append(draft); order.append("retain") }
    func reconcile(_ calls: CallCoordinator) {
        CallSceneReconciler.reconcile(hasCall: calls.hasCall, foreground: foreground,
            protectedDataAvailable: protectedDataAvailable) {
                voice.suspend(typed: &typed, target: lease, retain: { [self] in retain($0) }, disconnect: { [self] in
                    order.append("disconnect"); lease = nil; paired = false
                })
            }
    }
}

@Suite(.serialized) @MainActor struct CallSceneRegressionTests {
    private func terminal(_ cause: String, foreground: Bool = false, protectedData: Bool = false) async {
        let media = Rig(target: "ses_A")
        media.controller.app.sendMode = .manual
        await media.start()
        media.controller.composer.utterance("held before lock")
        let scene = SceneProbe()
        scene.lease = media.controller.currentLease
        let original = scene.lease!
        scene.foreground = foreground; scene.protectedDataAvailable = protectedData
        scene.voice.controller = media.controller
        let rig = CallCoordinatorRig()
        rig.calls.endMedia = {
            media.controller.onReviewDraft = { scene.retain($0) }
            media.controller.suspendForReview()
            media.controller.stop(discardUnfinished: true)
        }
        rig.calls.onTerminal = { scene.reconcile(rig.calls) }
        if cause == "readiness" { rig.begin = { false } }
        let provider = rig.start()
        provider.emit(.activated)
        if cause == "readiness" {
            #expect(await waitUntil { !rig.calls.hasCall })
        } else {
            #expect(await waitUntil { rig.calls.lifecycle.state == .active })
            // Lock has already happened; there is deliberately no further scene notification.
            if cause == "reset" { provider.emit(.reset) }
            else { provider.emit(.end(provider.id, { #expect($0) })) } // lock-screen End
        }
        #expect(!rig.calls.hasCall)
        #expect(scene.drafts.contains { $0.text == "held before lock" && $0.target == original })
        if !foreground || !protectedData {
            #expect(scene.lease == nil && !scene.paired && scene.typed.isEmpty)
            #expect(scene.drafts.contains { $0.text == "typed before lock" && $0.target == original })
            #expect(scene.order.last == "disconnect")
            #expect(scene.order.filter { $0 == "retain" }.count == 2)
        } else {
            #expect(scene.paired && scene.lease == original && scene.typed == "typed before lock")
            #expect(!scene.order.contains("disconnect"))
        }
        #expect(media.backend.prompts.isEmpty && media.backend.interrupts.isEmpty)
        provider.emit(.reset)
    }

    @Test func backgroundLockScreenEndSuspendsWithoutAnotherSceneEvent() async { await terminal("end") }
    @Test func backgroundProviderResetSuspendsWithoutAnotherSceneEvent() async { await terminal("reset") }
    @Test func backgroundReadinessFailureSuspendsWithoutAnotherSceneEvent() async { await terminal("readiness") }
    @Test func foregroundProtectedDataLossStillSuspendsAfterEnd() async { await terminal("end", foreground: true) }
    @Test func foregroundUnlockedEndKeepsHistoryConnected() async { await terminal("end", foreground: true, protectedData: true) }
}
