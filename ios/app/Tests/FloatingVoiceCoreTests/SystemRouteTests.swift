import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct SystemRouteTests {
    @Test func systemSpeakerOnOffKeepsReceiverBaselineAndHardwareLabel() {
        let audio = SessionModel(defaultSpeaker: false)
        let on = audio.system(true)
        #expect(audio.options == 4 && audio.route == .speaker && audio.label == "Speaker")
        #expect(on.source == .systemChoice)
        audio.repair()
        #expect(audio.options == 4 && audio.categoryWrites == 0)
        let off = audio.system(false)
        #expect(audio.options == 4 && audio.route == .phone && audio.label == "Phone")
        #expect(off.source == .systemChoice && off.generation != on.generation)
        #expect(audio.machine.policy.liveRoute == .phone)
    }
    @Test func appSpeakerIsClearableBySystemOff() throws {
        let audio = SessionModel(defaultSpeaker: false)
        let ticket = try audio.appToggle()
        #expect(audio.route == .speaker && audio.options == 4)
        #expect(ticket.source == .appToggle)
        let repairTicket = audio.tracker.engine(route: audio.route, now: 1.25)
        #expect(repairTicket == ticket)
        let off = audio.system(false)
        audio.repair()
        #expect(audio.route == .phone && audio.options == 4 && audio.label == "Phone")
        #expect(off.source == .systemChoice)
    }
    @Test func systemSpeakerThenAppReceiverDoesNotSaveOrReassertSpeaker() throws {
        let audio = SessionModel(defaultSpeaker: false)
        _ = audio.system(true)
        let ticket = try audio.appToggle()
        #expect(ticket.source == .appToggle && ticket.route == .phone)
        #expect(audio.route == .phone && audio.options == 4)
        audio.machine.policy.chooseSpeaker(true) // Saved next-call preference changes, not this call.
        audio.repair()
        #expect(audio.route == .phone && audio.options == 4 && audio.label == "Phone")
        #expect(audio.machine.policy.defaultSpeaker)
    }
    @Test func savedSpeakerStartsWithOneOverrideAndSystemOffReturnsToReceiver() throws {
        let audio = SessionModel(defaultSpeaker: true)
        #expect(audio.options == 4 && audio.route == .phone)
        audio.activate()
        #expect(audio.route == .speaker && audio.options == 4)
        _ = audio.system(false); audio.repair()
        #expect(audio.route == .phone && audio.options == 4)
        audio.activate(); audio.repair()
        #expect(audio.route == .phone && audio.options == 4 && audio.initialOverrides == 1)
        #expect(audio.machine.policy.defaultSpeaker) // No persistence change.
    }
    @Test func systemLiveChoiceCancelsInitialPreferenceAndOnlyNewCallCanBootstrap() {
        var policy = BuiltInRoutePolicy(defaultSpeaker: true)
        policy.begin(); policy.observe(.phone)
        let skipped = policy.activationOverride(current: .phone)
        #expect(skipped == nil)
        policy.chooseSpeaker(true)
        let notReapplied = policy.activationOverride(current: .phone)
        #expect(notReapplied == nil && !policy.categoryDefaultToSpeaker)
        policy.begin()
        let initial = policy.activationOverride(current: .phone)
        #expect(initial == true && !policy.categoryDefaultToSpeaker) // Only a NEW call bootstraps.
    }
    @Test func savedSpeakerNeverOverridesAirPodsHeadphonesExternalOrAlreadySelectedSpeaker() {
        for route in [PhoneAudioRoute.bluetooth, .headphones, .external, .speaker] {
            var policy = BuiltInRoutePolicy(defaultSpeaker: true); policy.begin()
            let initial = policy.activationOverride(current: route)
            let later = policy.activationOverride(current: .phone)
            #expect(initial == nil && later == nil && !policy.categoryDefaultToSpeaker)
        }
    }
    @Test func appChoiceBeforeGrantCancelsBootstrapAndInitialTicketIsDeliberate() {
        var policy = BuiltInRoutePolicy(defaultSpeaker: true); policy.begin()
        _ = policy.explicitOverride(current: .speaker, speaker: false)
        let initial = policy.activationOverride(current: .phone)
        #expect(initial == nil)
        var tracker = RouteRecoveryTracker(); tracker.begin(route: .phone)
        let ticket = tracker.expect(.speaker, now: 0, source: .initialPreference)
        let observed = tracker.notification(route: .speaker, reason: 4, now: 0.1)
        #expect(observed == ticket && observed.deliberate && observed.source == .initialPreference)
        var budget = RouteRecoveryBudget()
        let admitted = budget.admit(observed, now: 0.1)
        #expect(admitted && budget.unexpected.isEmpty)
    }
    @Test func lostInitialOverrideDuringRepairIsNeverReassertedEvenAfterReactivation() {
        let audio = SessionModel(defaultSpeaker: true)
        audio.activate()
        #expect(audio.route == .speaker && audio.initialOverrides == 1)
        audio.speakerOverride = false // Simulate engine/session churn, NOT a live user choice.
        audio.repair(); audio.activate(); audio.repair()
        #expect(audio.route == .phone && audio.options == 4 && audio.initialOverrides == 1)
    }
    @Test func failedInitialOverrideIsConsumedNotRetriedAndSavedChangesWaitForNewCall() {
        var policy = BuiltInRoutePolicy(defaultSpeaker: true); policy.begin()
        let attempted = policy.activationOverride(current: .phone) // Native override may throw after consumption.
        let retry = policy.activationOverride(current: .phone)
        #expect(attempted == true && retry == nil)
        policy.chooseSpeaker(false); policy.begin(); policy.chooseSpeaker(true)
        let unchangedCallDefault = policy.activationOverride(current: .phone)
        #expect(unchangedCallDefault == nil)
        policy.begin()
        let nextCall = policy.activationOverride(current: .phone)
        #expect(nextCall == true)
    }
    @Test func ticketsRemainDeliberateWithoutSpendingUnexpectedRepairBudget() throws {
        let audio = SessionModel(defaultSpeaker: false)
        var budget = RouteRecoveryBudget()
        let systemOn = audio.system(true)
        let admittedSystem = budget.admit(systemOn, now: 1)
        #expect(admittedSystem)
        let appOff = try audio.appToggle()
        let admittedApp = budget.admit(appOff, now: 1.25)
        #expect(admittedApp)
        let systemOnAgain = audio.system(true)
        let admittedAgain = budget.admit(systemOnAgain, now: 1.5)
        #expect(admittedAgain)
        #expect(budget.unexpected.isEmpty && !budget.paused)
        #expect(audio.options == 4)
    }
}

/// Models the documented AVAudioSession rule: .none resolves to the category
/// default. This reproduces the old4→12 sticky-speaker bug, not just a Bool toggle.
@MainActor private final class SessionModel {
    var machine: LiveRouteSwitch
    var tracker = RouteRecoveryTracker()
    var defaultBit: Bool
    var speakerOverride = false
    var categoryWrites = 0
    var initialOverrides = 0
    var route: PhoneAudioRoute { speakerOverride || defaultBit ? .speaker : .phone }
    var options: Int { defaultBit ? 12 : 4 }
    var label: String { route == .speaker ? "Speaker" : "Phone" }
    init(defaultSpeaker: Bool) {
        machine = LiveRouteSwitch(defaultSpeaker: defaultSpeaker); machine.policy.begin()
        defaultBit = machine.policy.categoryDefaultToSpeaker
        tracker.begin(route: route)
    }
    func activate() {
        if machine.policy.activationOverride(current: route) == true {
            let ticket = tracker.expect(.speaker, now: 0, source: .initialPreference)
            speakerOverride = true; initialOverrides += 1
            let observed = tracker.notification(route: route, reason: 4, now: 0.1)
            #expect(observed == ticket)
        }
    }
    @discardableResult func system(_ speaker: Bool) -> RouteRecoveryContext {
        speakerOverride = speaker
        let ticket = tracker.notification(route: route, reason: 4, now: 1)
        machine.observe(route, systemSelection: true)
        return ticket
    }
    func appToggle() throws -> RouteRecoveryContext {
        let expected: PhoneAudioRoute = route == .speaker ? .phone : .speaker
        let ticket = tracker.expect(expected, now: 1)
        var transaction = machine
        try transaction.toggle(active: true, mayRunMedia: true, current: { self.route }, apply: { speaker in
            if self.defaultBit { self.categoryWrites += 1 }
            self.defaultBit = false; self.speakerOverride = speaker
        }, diagnostic: { _ in })
        machine = transaction
        #expect(tracker.notification(route: route, reason: 4, now: 1.1) == ticket)
        return ticket
    }
    func repair() {
        let next = false // Every category configuration is allowBluetooth-only.
        if next != defaultBit { categoryWrites += 1; defaultBit = next; speakerOverride = false }
    }
}
