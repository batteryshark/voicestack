import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct CallGrantBarrierTests {
    private func invitation() -> PushInvitation {
        PushInvitation(payload: ["reachoutID": "grant-test", "callUUID": UUID().uuidString,
            "expiry": Date().addingTimeInterval(30).timeIntervalSince1970 * 1000,
            "ringDeadline": Date().addingTimeInterval(10).timeIntervalSince1970 * 1000])
    }
    @Test func unholdThenEndBlocksStartAndPushUntilLateGrantReallyReleases() async {
        for push in [false, true] {
            let rig = CallCoordinatorRig(), old = await rig.active()
            rig.calls.hold(true); old.emit(.deactivated); rig.calls.hold(false)
            rig.calls.end()
            if push { rig.calls.receivePush(invitation(), allowed: true) {} } else { rig.calls.start(target: rig.target) }
            #expect(rig.providers.count == 1 && !rig.calls.hasCall)
            old.emit(.activated) // Actual shared-session grant to the RETIRING Unhold generation.
            rig.calls.start(target: rig.target)
            #expect(rig.providers.count == 1 && !rig.calls.hasCall)
            old.emit(.deactivated)
            if push {
                let next = invitation(); rig.calls.receivePush(next, allowed: true) {}
                #expect(rig.providers.count == 2 && rig.calls.hasCall && rig.calls.lifecycle.id == next.id)
                rig.calls.end()
            } else {
                let next = rig.start(); next.emit(.activated)
                #expect(await waitUntil { rig.calls.lifecycle.state == .active })
                old.emit(.activated); old.emit(.deactivated); old.emit(.reset)
                #expect(rig.calls.hasCall && rig.calls.lifecycle.mayRunMedia)
                rig.cleanup(next)
            }
        }
    }
    @Test func oldHoldDeactivationDoesNotConsumePendingUnholdGeneration() async {
        let rig = CallCoordinatorRig(), old = await rig.active()
        rig.calls.hold(true); rig.calls.hold(false) // Fresh Unhold while OLD active grant still drains.
        rig.calls.end()
        old.emit(.deactivated) // Releases OLD grant only, not the queued Unhold.
        rig.calls.start(target: rig.target)
        #expect(rig.providers.count == 1)
        old.emit(.activated)
        rig.calls.start(target: rig.target)
        #expect(rig.providers.count == 1)
        old.emit(.deactivated) // Now the Unhold generation itself has actually released.
        let next = rig.start()
        #expect(rig.providers.count == 2)
        rig.cleanup(next)
    }
    @Test func plainHoldUnholdActivateEndStillWaitsForItsRealRelease() async {
        let rig = CallCoordinatorRig(), old = await rig.active()
        rig.calls.hold(true); old.emit(.deactivated); rig.calls.hold(false); old.emit(.activated)
        #expect(await waitUntil { rig.starts == 2 && rig.calls.lifecycle.state == .active })
        rig.calls.end(); rig.calls.start(target: rig.target)
        #expect(rig.providers.count == 1)
        old.emit(.deactivated)
        let next = rig.start()
        #expect(rig.providers.count == 2)
        rig.cleanup(next)
    }
    @Test func everActivatedProviderIsNotIdleJustBecauseItWasHeldAndDeactivated() async {
        let rig = CallCoordinatorRig(), old = await rig.active()
        rig.calls.hold(true); old.emit(.deactivated); rig.calls.end()
        rig.calls.start(target: rig.target)
        #expect(rig.providers.count == 1)
        old.emit(.reset) // Definitive provider barrier, even if no new audio grant arrives.
        let next = rig.start()
        #expect(rig.providers.count == 2)
        rig.cleanup(next)
    }
    @Test func interruptionReactivationRemainsPendingAcrossOldReleaseAndEnd() async {
        let rig = CallCoordinatorRig(), old = await rig.active()
        rig.calls.interrupted(); old.emit(.deactivated); rig.calls.end()
        rig.calls.start(target: rig.target)
        #expect(rig.providers.count == 1)
        old.emit(.activated); rig.calls.start(target: rig.target)
        #expect(rig.providers.count == 1)
        old.emit(.deactivated)
        let next = rig.start()
        #expect(rig.providers.count == 2)
        rig.cleanup(next)
    }
    @Test func duplicateOldReleaseCannotCancelAnUnobservedFutureUnholdGrant() async {
        let rig = CallCoordinatorRig(), old = await rig.active()
        rig.calls.hold(true); old.emit(.deactivated); rig.calls.hold(false); rig.calls.end()
        old.emit(.deactivated) // Old/duplicate release, before the queued fresh grant was ever observed.
        rig.calls.start(target: rig.target)
        #expect(rig.providers.count == 1)
        old.emit(.activated); rig.calls.start(target: rig.target)
        #expect(rig.providers.count == 1)
        old.emit(.deactivated)
        let next = rig.start()
        #expect(rig.providers.count == 2)
        rig.cleanup(next)
    }
}
