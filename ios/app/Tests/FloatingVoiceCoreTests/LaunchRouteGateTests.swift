import Foundation
import Testing
@testable import FloatingVoiceCore

@MainActor struct LaunchRouteGateTests {
    private func state(active: Bool = true, unlocked: Bool = true, paired: Bool = true,
                       preparing: Bool = false, backend: Bool = true, call: Bool = false) -> LaunchRouteGate.Readiness {
        .init(active: active, unlocked: unlocked, paired: paired, preparing: preparing, hasBackend: backend, hasCall: call)
    }
    @Test func coldInactiveMountWaitsForActiveStartupAndIdleThenRoutesOnce() async throws {
        let gate = LaunchRouteGate()
        let startup = [state(active: false, paired: false, backend: false),
                       state(paired: false, preparing: true, backend: false),
                       state(preparing: true), state()]
        var tick = 0, routes = 0
        let ran = try await gate.run(now: { Double(tick) }, sleep: { tick += 1 },
            readiness: { startup[tick] }) { #expect(tick == 3); routes += 1 }
        #expect(ran && routes == 1)
        #expect(try await gate.run(readiness: { state() }, route: { routes += 1 }) == false)
        #expect(routes == 1)
    }
    @Test func pairedButPreparingIsNotReadyAndProtectedDataMustBeAvailable() async throws {
        let gate = LaunchRouteGate()
        var tick = 0, routes = 0
        try await gate.run(now: { Double(tick) }, sleep: { tick += 1 }, readiness: {
            tick == 0 ? state(preparing: true) : tick == 1 ? state(unlocked: false) : state()
        }) { routes += 1 }
        #expect(tick == 2 && routes == 1)
    }
    @Test func missingBackendCannotRouteDespitePairedFlag() async throws {
        let gate = LaunchRouteGate(); var tick = 0, routes = 0
        do {
            try await gate.run(timeout: 2, now: { Double(tick) }, sleep: { tick += 1 },
                readiness: { state(backend: false) }, route: { routes += 1 })
            Issue.record("Missing backend routed")
        } catch { #expect(error as? NotificationRouteFailure == .preparation) }
        #expect(tick == 2 && routes == 0)
        #expect(try await gate.run(readiness: { state() }, route: { routes += 1 }) == false)
    }
    @Test func concurrentMountDoesNotDuplicateWaitingRoute() async throws {
        let gate = LaunchRouteGate(); var ready = false, routes = 0
        let first = Task { try await gate.run(sleep: { await Task.yield() },
            readiness: { state(active: ready) }) { routes += 1 } }
        while !gate.claimed { await Task.yield() }
        #expect(try await gate.run(readiness: { state() }, route: { routes += 1 }) == false)
        ready = true; #expect(try await first.value)
        #expect(routes == 1)
    }
    @Test func cancellationBeforeReadyNeverRoutesOnRemount() async throws {
        let gate = LaunchRouteGate(); var routes = 0
        let task = Task { try await gate.run(sleep: { await Task.yield() },
            readiness: { state(active: false) }) { routes += 1 } }
        while !gate.claimed { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancellation ignored") }
        catch { #expect(error is CancellationError) }
        #expect(try await gate.run(readiness: { state() }, route: { routes += 1 }) == false)
        #expect(routes == 0)
    }
    @Test func failedRouteIsNeverReplayed() async throws {
        let gate = LaunchRouteGate(); var routes = 0
        do { try await gate.run(readiness: { state() }) { routes += 1; throw NotificationRouteFailure.messageUnavailable } }
        catch { #expect(error as? NotificationRouteFailure == .messageUnavailable) }
        #expect(try await gate.run(readiness: { state() }, route: { routes += 1 }) == false)
        #expect(routes == 1)
    }
    @Test func callFailsClosedWithoutWaitingOrRouting() async throws {
        let gate = LaunchRouteGate()
        do { try await gate.run(readiness: { state(call: true) }) { Issue.record("Call target changed") } }
        catch { #expect(error as? NotificationRouteFailure == .targetChanged) }
    }
}
