import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite @MainActor struct CallHoldRegressionTests {
    private func activeCall() -> (CallLifecycle, Int) {
        let call = CallLifecycle()
        let epoch = call.begin(target: .init(sessionID: "ses_A", generation: "one"))!
        call.connecting(epoch); call.activate(epoch); call.ready(epoch)
        return (call, epoch)
    }
    @Test func unholdBeforeDeactivationCannotReuseGrant() {
        let (call, epoch) = activeCall()
        call.hold(true, owner: epoch)
        #expect(!call.activationGranted)
        call.hold(false, owner: epoch)
        #expect(!call.mayRunMedia && !call.ready(epoch))
    }
    @Test func activationWhileHeldCannotBeBankedForUnhold() {
        let (call, epoch) = activeCall()
        call.hold(true, owner: epoch)
        #expect(!call.activate(epoch) && !call.activationGranted)
        call.hold(false, owner: epoch)
        #expect(!call.mayRunMedia)
        call.deactivate(); call.activate(epoch)
        #expect(call.mayRunMedia)
    }
    @Test func delayedDeactivationRevokesResumedSetupReadiness() {
        let (call, epoch) = activeCall()
        call.hold(true, owner: epoch); call.hold(false, owner: epoch)
        #expect(!call.mayRunMedia)
        call.deactivate(); call.activate(epoch)
        #expect(call.mayRunMedia)
        call.deactivate() // setup's completion is now too late to mark connected
        #expect(!call.ready(epoch))
    }
}
