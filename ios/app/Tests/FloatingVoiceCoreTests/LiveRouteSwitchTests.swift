import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite(.serialized) @MainActor struct LiveRouteSwitchTests {
    @Test func missingDefaultIsReceiverAndExplicitSavedSpeakerSurvives() {
        let suite = "route28-" + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        #expect(!SpeakerRoutePreference.load(isolated))
        isolated.set(true, forKey: "call.defaultSpeaker")
        #expect(SpeakerRoutePreference.load(isolated)) // explicit legacy setting
        SpeakerRoutePreference.save(false, isolated)
        #expect(!SpeakerRoutePreference.load(isolated))
        SpeakerRoutePreference.save(true, isolated)
        #expect(SpeakerRoutePreference.load(isolated))
    }
    @Test func everyGuardIsDiagnosedAndThrowsInsteadOfSilentlyReturning() {
        for (active, media, route, gate) in [(false, true, PhoneAudioRoute.speaker, RouteGuard.inactive),
            (true, false, .speaker, .mediaBlocked), (true, true, .bluetooth, .externalRoute)] {
            var machine = LiveRouteSwitch(defaultSpeaker: true), rows: [RouteDiagnostic] = [], applies = 0
            #expect(throws: RouteSwitchError.self) {
                try machine.toggle(active: active, mayRunMedia: media, current: { route }, apply: { _ in applies += 1 }, diagnostic: { rows.append($0) })
            }
            #expect(applies == 0 && rows.count == 1)
            #expect(rows[0].gate == gate && rows[0].result == .rejected && rows[0].action == .none)
        }
    }
    @Test func failedAPIDoesNotCommitChoiceAndExposesCalmError() {
        var machine = LiveRouteSwitch(defaultSpeaker: true), rows: [RouteDiagnostic] = []
        do {
            try machine.toggle(active: true, mayRunMedia: true, current: { .speaker }, apply: { _ in throw ClientError("Private OS detail") }, diagnostic: { rows.append($0) })
            Issue.record("Must throw")
        } catch { #expect(error.localizedDescription == RouteSwitchError.failed.localizedDescription) }
        #expect(machine.policy.liveRoute == nil && !machine.policy.categoryDefaultToSpeaker && machine.policy.defaultSpeaker)
        #expect(rows.map(\.result) == [.requested, .failed])
    }
    @Test func routeErrorsRemainCalmAndVisibleEvenWhileCaptureRuns() {
        for error in [RouteSwitchError.unavailable, .failed] {
            #expect(PrincipalError.message(error.localizedDescription, captureRunning: true) == error.localizedDescription)
        }
    }
    @Test func speakerPhoneSpeakerPersistsAcrossRecoveryWithoutSavingDefault() throws {
        var machine = LiveRouteSwitch(defaultSpeaker: true), current = PhoneAudioRoute.speaker
        var applied: [Bool] = [], rows: [RouteDiagnostic] = []
        for expected in [PhoneAudioRoute.phone, .speaker, .phone] {
            try machine.toggle(active: true, mayRunMedia: true, current: { current }, apply: { speaker in
                applied.append(speaker); current = speaker ? .speaker : .phone
            }, diagnostic: { rows.append($0) })
            #expect(current == expected && machine.policy.liveRoute == expected)
            #expect(!machine.policy.categoryDefaultToSpeaker)
            machine.policy.observe(current) // notification/recovery reads same live policy
            #expect(!machine.policy.categoryDefaultToSpeaker)
            machine.policy.chooseSpeaker(true) // Settings is NEXT call, not recovery
            #expect(!machine.policy.categoryDefaultToSpeaker)
            #expect(machine.policy.activationOverride(current: current) == nil)
        }
        #expect(applied == [false, true, false] && rows.count == 6)
        machine.policy.begin() // only a NEW provider resets the route
        #expect(!machine.policy.categoryDefaultToSpeaker && machine.policy.liveRoute == nil)
        let initial = machine.policy.activationOverride(current: .phone)
        #expect(initial == true)
    }
    @Test func systemChoicesBothWaysAndExternalAreObservedNeverOverridden() {
        var machine = LiveRouteSwitch(defaultSpeaker: true)
        _ = machine.policy.explicitOverride(current: .phone, speaker: true)
        for route in [PhoneAudioRoute.phone, .speaker, .bluetooth, .headphones, .phone] {
            machine.policy.observe(route)
            #expect(!machine.policy.categoryDefaultToSpeaker)
            #expect(machine.policy.activationOverride(current: route) == nil)
            #expect(machine.policy.defaultSpeaker) // system route isn't a saved choice
        }
    }
    @Test func engineCategoryChurnNeverReplacesLiveChoiceButSystemSelectionDoes() {
        var machine = LiveRouteSwitch(defaultSpeaker: true)
        _ = machine.policy.explicitOverride(current: .speaker, speaker: false)
        machine.observe(.speaker, systemSelection: false)
        #expect(!machine.policy.categoryDefaultToSpeaker && machine.policy.liveRoute == .phone)
        machine.observe(.speaker, systemSelection: true)
        #expect(!machine.policy.categoryDefaultToSpeaker && machine.policy.liveRoute == .speaker)
        machine.observe(.bluetooth, systemSelection: false)
        #expect(!machine.policy.categoryDefaultToSpeaker && machine.policy.liveRoute == .bluetooth)
    }
    @Test func routeDiagnosticEncodingContainsOnlyClosedRouteValues() throws {
        let log = StageDiagnostics()
        log.record(.route, .failed, audio: CaptureSnapshot([.routeReason: 4, .categoryOptions: 12]),
            audioRoute: RouteDiagnostic(event: .toggle, gate: .inactive, before: .speaker, after: .speaker, result: .rejected))
        let rows = try JSONDecoder().decode([DiagnosticEntry].self, from: Data(log.export().utf8))
        #expect(rows[0].audioRoute?.gate == .inactive && rows[0].stage == .route)
        #expect(rows[0].audio?.values["routeReason"] == 4)
        #expect(!log.export().contains("Private OS detail"))
    }
    @Test func incomingAndOutgoingUseSameActivationGatesAndProductionToggleMachine() async throws {
        for incoming in [false, true] {
            var p: RouteProvider!
            let calls = CallCoordinator(makeProvider: { lifecycle in p = RouteProvider(lifecycle); return p })
            calls.beginMedia = { _ in true }
            let target = TargetLease(sessionID: "ses_route", generation: "test")
            if incoming {
                let invitation = PushInvitation(payload: ["reachoutID": "route-test", "callUUID": UUID().uuidString,
                    "expiry": Date().addingTimeInterval(60).timeIntervalSince1970 * 1000,
                    "ringDeadline": Date().addingTimeInterval(30).timeIntervalSince1970 * 1000])
                calls.resolveIncoming = { _ in target }
                calls.receivePush(invitation, allowed: true) {}
                p.onEvent?(.answer(invitation.id, { #expect($0) }))
                #expect(await waitUntil { p.configured })
            } else {
                calls.start(target: target); p.onEvent?(.start(calls.lifecycle.id!, { #expect($0) }))
            }
            p.toggleSpeaker() // before didActivate: diagnosed failure
            #expect(p.rows.last?.gate == .inactive && p.errors == 1)
            p.onEvent?(.activated)
            #expect(await waitUntil { calls.lifecycle.state == .active })
            #expect(p.active && p.lifecycle === calls.lifecycle)
            for expected in [PhoneAudioRoute.speaker, .phone, .speaker] {
                p.toggleSpeaker(); #expect(p.current == expected)
                p.machine.policy.observe(expected) // system notification before engine repair
                #expect(!p.machine.policy.categoryDefaultToSpeaker)
            }
            p.current = .phone; p.machine.policy.observe(.phone); p.onEvent?(.routeChanged)
            #expect(!p.machine.policy.categoryDefaultToSpeaker)
            p.onEvent?(.deactivated); p.toggleSpeaker()
            #expect(p.rows.last?.gate == .inactive)
            p.onEvent?(.activated)
            #expect(await waitUntil { calls.lifecycle.state == .active })
            p.toggleSpeaker(); #expect(p.current == .speaker)
            calls.end(); p.onEvent?(.reset)
        }
    }
}

@MainActor private final class RouteProvider: CallProviderAdapter {
    var onEvent: ((CallProviderEvent) -> Void)?
    let lifecycle: CallLifecycle
    var machine = LiveRouteSwitch(defaultSpeaker: false)
    var current = PhoneAudioRoute.phone, active = false, configured = false
    var rows: [RouteDiagnostic] = [], errors = 0
    init(_ lifecycle: CallLifecycle) { self.lifecycle = lifecycle; machine.policy.begin() }
    var routeLabel: String { current.rawValue }
    func toggleSpeaker() {
        var transaction = machine
        do { try transaction.toggle(active: active, mayRunMedia: lifecycle.mayRunMedia, current: { self.current },
            apply: { self.current = $0 ? .speaker : .phone }, diagnostic: { self.rows.append($0) }); machine = transaction }
        catch { errors += 1 }
    }
    func observeActivation(_ granted: Bool) { active = granted }
    func requestStart(_ id: UUID, completion: @escaping (Error?) -> Void) { completion(nil) }
    func reportIncoming(_ id: UUID, completion: @escaping (Error?) -> Void) { completion(nil) }
    func requestEnd(_ id: UUID) {}
    func requestMute(_ id: UUID, muted: Bool) {}
    func requestHold(_ id: UUID, held: Bool) {}
    func configure() throws { configured = true }
    func connecting(_ id: UUID) {}
    func connected(_ id: UUID) {}
    func ended(_ id: UUID, reason: CallEndReason) {}
    func refresh(proximity: Bool) {}
    func invalidate() {}
}
