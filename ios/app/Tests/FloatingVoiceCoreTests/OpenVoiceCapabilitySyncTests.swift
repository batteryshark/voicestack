import XCTest
@testable import FloatingVoiceCore

@MainActor private final class CapabilityRig {
    var saved: OpenVoiceCapabilitySync.State
    var requests: [Bool] = []
    var pending: CheckedContinuation<Date,Error>?
    var active = 0, peak = 0, saves = 0
    var failStorage = false
    var sync: OpenVoiceCapabilitySync!
    init(_ state: OpenVoiceCapabilitySync.State = .init(desiredEnabled:false,mayBeEnabled:false)) {
        saved = state
        sync = OpenVoiceCapabilitySync(state:state,persist:{ [unowned self] value in
            saves += 1
            if failStorage { throw ClientError("fixture storage unavailable") }
            saved = value
        },upload:{ [unowned self] enabled in
            if enabled { XCTAssertTrue(saved.mayBeEnabled); XCTAssertTrue(saved.enableNeedsExplicitChoice) }
            requests.append(enabled); active += 1; peak = max(peak,active)
            defer { active -= 1 }
            return try await withCheckedThrowingContinuation { pending = $0 }
        })
    }
    func edit(_ enabled: Bool) { sync.setDesired(enabled); sync.refresh() }
    func finish(_ success: Bool = true) {
        let waiter = pending; pending = nil
        if success { waiter?.resume(returning:Date().addingTimeInterval(200)) }
        else { waiter?.resume(throwing:ClientError("fixture uncertain upload")) }
    }
    func waitRequests(_ count: Int) async {
        let arrived = await waitUntil { self.requests.count == count && self.pending != nil }
        XCTAssertTrue(arrived)
    }
    func waitIdle() async { let idle = await waitUntil { !self.sync.running }; XCTAssertTrue(idle) }
}

final class OpenVoiceCapabilitySyncTests: XCTestCase {
    @MainActor func testNeverAdvertisedDefaultFalseNeverEntersCandidatePlane() async {
        let r = CapabilityRig()
        for _ in 0..<100 { r.sync.refresh() }
        XCTAssertFalse(r.sync.running); XCTAssertTrue(r.requests.isEmpty); XCTAssertEqual(r.saves,0)
        r.edit(true); r.edit(false) // both edits before the worker gets an executor turn
        await r.waitIdle()
        XCTAssertTrue(r.requests.isEmpty); XCTAssertFalse(r.saved.mayBeEnabled)
    }
    @MainActor func testDisableDuringPendingEnableFollowsSuccessOrUncertaintyWithFalse() async {
        for enableSucceeded in [true,false] {
            let r = CapabilityRig(); r.edit(true); await r.waitRequests(1)
            XCTAssertTrue(r.saved.mayBeEnabled) // durable BEFORE the first async request
            r.edit(false)
            for _ in 0..<100 { r.sync.refresh() }
            XCTAssertFalse(r.saved.desiredEnabled); XCTAssertEqual(r.sync.expiresAt,.distantPast)
            XCTAssertEqual(r.requests,[true]); r.finish(enableSucceeded)
            await r.waitRequests(2); XCTAssertEqual(r.requests,[true,false]); XCTAssertEqual(r.peak,1)
            r.finish(); await r.waitIdle()
            XCTAssertFalse(r.saved.desiredEnabled); XCTAssertFalse(r.saved.mayBeEnabled)
            r.sync.refresh(); XCTAssertFalse(r.sync.running)
        }
    }
    @MainActor func testLatestTrueFalseTrueCoalescesWithoutRepeatingPendingTrue() async {
        for success in [true,false] {
            let r = CapabilityRig(); r.edit(true); await r.waitRequests(1)
            r.edit(false); r.edit(true)
            let restartedWhilePending = CapabilityRig(r.saved)
            restartedWhilePending.sync.refresh()
            XCTAssertTrue(r.saved.enableNeedsExplicitChoice)
            XCTAssertFalse(restartedWhilePending.sync.running); XCTAssertTrue(restartedWhilePending.requests.isEmpty)
            r.finish(success); await r.waitIdle()
            XCTAssertEqual(r.requests,[true]); XCTAssertEqual(r.peak,1)
            if success { XCTAssertGreaterThan(r.sync.expiresAt,Date()) }
            else {
                XCTAssertEqual(r.sync.expiresAt,.distantPast); XCTAssertTrue(r.saved.enableNeedsExplicitChoice)
                r.sync.refresh(); XCTAssertFalse(r.sync.running) // no automatic true retry
            }
        }
    }
    @MainActor func testEnableDuringPendingDisableWaitsAndUsesLatestDesiredState() async {
        for disableSucceeded in [true,false] {
            let r = CapabilityRig(.init(desiredEnabled:false,mayBeEnabled:true))
            r.sync.refresh(); await r.waitRequests(1); r.edit(true)
            XCTAssertEqual(r.requests,[false]); r.finish(disableSucceeded)
            await r.waitRequests(2); XCTAssertEqual(r.requests,[false,true]); XCTAssertEqual(r.peak,1)
            r.finish(); await r.waitIdle(); XCTAssertTrue(r.saved.mayBeEnabled)
            XCTAssertGreaterThan(r.sync.expiresAt,Date())
        }
    }
    @MainActor func testFailedFalseKeepsDurableMaybeGuardForForegroundAndRestart() async {
        for enableSucceeded in [true,false] {
            let r = CapabilityRig(); r.edit(true); await r.waitRequests(1)
            r.edit(false); r.finish(enableSucceeded); await r.waitRequests(2)
            r.finish(false); await r.waitIdle()
            XCTAssertTrue(r.saved.mayBeEnabled); XCTAssertFalse(r.saved.desiredEnabled)
            r.sync.refresh(); await r.waitRequests(3); XCTAssertEqual(r.requests,[true,false,false])
            r.finish(false); await r.waitIdle()
            let restarted = CapabilityRig(r.saved)
            restarted.sync.refresh(); await restarted.waitRequests(1); XCTAssertEqual(restarted.requests,[false])
            restarted.finish(); await restarted.waitIdle(); XCTAssertFalse(restarted.saved.mayBeEnabled)
        }
    }
    @MainActor func testPendingDisableEnableDisableNeverRevivesSupersededEnable() async {
        for success in [true,false] {
            let r = CapabilityRig(.init(desiredEnabled:false,mayBeEnabled:true))
            r.sync.refresh(); await r.waitRequests(1)
            r.edit(true); r.edit(false); r.finish(success); await r.waitIdle()
            XCTAssertEqual(r.requests,[false]); XCTAssertFalse(r.saved.desiredEnabled)
            XCTAssertEqual(r.saved.mayBeEnabled,!success)
            XCTAssertEqual(r.sync.expiresAt,.distantPast)
        }
    }
    @MainActor func testUncertainEnableDoesNotReenableOnForegroundOrRestartButOptOutCorrectsIt() async {
        let r = CapabilityRig(); r.edit(true); await r.waitRequests(1); r.finish(false); await r.waitIdle()
        r.sync.refresh(); XCTAssertFalse(r.sync.running)
        let restarted = CapabilityRig(r.saved); restarted.sync.refresh()
        XCTAssertFalse(restarted.sync.running); XCTAssertTrue(restarted.requests.isEmpty)
        restarted.edit(false); await restarted.waitRequests(1)
        XCTAssertEqual(restarted.requests,[false]); restarted.finish(); await restarted.waitIdle()
    }
    @MainActor func testRestartDuringEnableUsesPersistedMaybeGuardForDisabledChoice() async {
        let r = CapabilityRig(); r.edit(true); await r.waitRequests(1); r.edit(false)
        let restarted = CapabilityRig(r.saved)
        restarted.sync.refresh(); await restarted.waitRequests(1); XCTAssertEqual(restarted.requests,[false])
        restarted.finish(); await restarted.waitIdle()
        r.finish(false); await r.waitRequests(2); r.finish(); await r.waitIdle()
    }
    @MainActor func testUndurableEnableNeverUploadsOrSpins() async {
        let r = CapabilityRig(); r.failStorage = true; r.edit(true); await r.waitIdle()
        XCTAssertTrue(r.requests.isEmpty); r.sync.refresh(); XCTAssertFalse(r.sync.running)
        XCTAssertEqual(r.sync.expiresAt,.distantPast)
    }
}
