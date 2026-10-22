import Foundation

/// One media owner, no reconnection/replacement, inference, or audio-device access.
/// Future capture owner must call signalWrites after writes; periodic tick is a bounded
/// safety wake. No per-frame Task, unbounded stream, or automatic native activation.
@MainActor public final class OpenVoiceMediaOwnerPump {
    public let client: OpenVoiceClient
    public let fence: OpenVoiceMediaFence
    public private(set) var running = false
    public var reportedReady: Bool { client.mediaReadyAccepted }
    private let socket: OpenVoiceURLSessionSocket
    private let lease: OpenVoiceMediaLease
    private let readinessOwner = UUID()
    private let clock: () -> TimeInterval
    private var receiver: Task<Void,Never>?, writer: Task<Void,Never>?
    private var ticker: DispatchSourceTimer?
    private var writeSignal: CheckedContinuation<Void,Never>?
    private var signalled = false, started = false, configuredRequested = false, readinessAttempted = false
    private var readinessConfirmed = false, readinessReporting = false

    public convenience init(socket: OpenVoiceURLSessionSocket, lease: OpenVoiceMediaLease, localCallEpoch: UUID) throws {
        try self.init(socket:socket,lease:lease,localCallEpoch:localCallEpoch,clock:{ ProcessInfo.processInfo.systemUptime })
    }
    init(socket: OpenVoiceURLSessionSocket, lease: OpenVoiceMediaLease, localCallEpoch: UUID, clock: @escaping () -> TimeInterval) throws {
        try OpenVoiceWire.check(socket.matches(lease))
        self.socket = socket; self.lease = lease
        self.clock = clock
        fence = OpenVoiceMediaFence(call:localCallEpoch,media:lease.epoch)
        client = try OpenVoiceClient(socket:socket,fence:fence,committedItemLimit:OpenVoiceClient.maxCommittedItems,mediaOwnerToken:readinessOwner)
    }
    public func start() async throws {
        try OpenVoiceWire.check(!started, "local_failure"); started = true; running = true
        do { try await socket.open(); try Task.checkCancellation(); try OpenVoiceWire.check(running) }
        catch { stop(); throw OpenVoiceFailure("local_failure") }
        receiver = Task { [weak self] in
            guard let self else { return }
            do {
                while self.running && !Task.isCancelled {
                    try await self.client.receiveOne(clock:self.clock)
                    if self.client.state == .created && !self.configuredRequested {
                        self.configuredRequested = true
                        try self.client.enqueue(.object(["type":.string("session.update"),"session":.object(["type":.string("realtime")])]))
                    }
                    if self.client.state == .failed || self.client.state == .closed { self.stop(); break }
                    self.signalWrites()
                }
            } catch { self.client.fail(); self.stop() }
        }
        writer = Task { [weak self] in
            guard let self else { return }
            do {
                while self.running && !Task.isCancelled {
                    await self.waitForWrites()
                    guard self.running && !Task.isCancelled else { break }
                    // The common client boundary gates media and serializes/joiners
                    // for this writer and buffered recognition alike.
                    try await self.client.flush()
                    if self.client.state == .failed || self.client.state == .closed { self.stop(); break }
                }
            } catch { self.client.fail(); self.stop() }
        }
        let timer = DispatchSource.makeTimerSource(queue:.main)
        timer.schedule(deadline:.now() + 0.25,repeating:0.25)
        timer.setEventHandler { [weak self] in MainActor.assumeIsolated {
            guard let self, self.running else { return }
            self.client.tick(now:self.clock(),fence:self.fence)
            if self.client.state == .failed || self.client.state == .closed { self.stop() }
            else { self.signalWrites() }
        } }
        ticker = timer; timer.resume()
    }
    public func signalWrites() {
        guard running else { return }
        if let waiting = writeSignal { writeSignal = nil; waiting.resume() }
        else { signalled = true }
    }
    private func waitForWrites() async {
        if signalled { signalled = false; return }
        await withCheckedContinuation { writeSignal = $0 }
    }
    public func nativeCaptureReady(_ ready: Bool, fence: OpenVoiceMediaFence) {
        guard running && fence == self.fence else { return }
        client.setNativeActivated(ready,fence:fence)
        // The client revokes accepted readiness even through direct public access.
        signalWrites()
    }
    public func reportReadiness(using control: OpenVoiceRecipientControl) async throws {
        try OpenVoiceWire.check(running && socket.isOpen && client.state == .ready && !readinessReporting && (!readinessAttempted || readinessConfirmed))
        guard let id = client.effectiveSession?["id"].string else { throw OpenVoiceFailure() }
        readinessAttempted = true // Uncertain readiness POST is never automatically replayed.
        readinessConfirmed = false; readinessReporting = true
        defer { readinessReporting = false }
        let epoch = client.readinessEpoch
        try await control.mediaReady(OpenVoiceMediaReadiness(lease:lease,sessionID:id))
        readinessConfirmed = true // Known ACK may be reasserted only for a new real capture grant.
        try OpenVoiceWire.check(running && socket.isOpen && client.effectiveSession?["id"].string == id)
        guard client.readinessEpoch == epoch && client.state == .ready else { return }
        try client.acceptMediaReady(owner:readinessOwner,fence:fence,sessionID:id,epoch:epoch)
        signalWrites()
    }
    public func stop() {
        guard running else { socket.close(); client.close(); return }; running = false
        ticker?.cancel(); ticker = nil; signalled = false
        let waiting = writeSignal; writeSignal = nil; waiting?.resume()
        receiver?.cancel(); writer?.cancel(); socket.close(); client.close()
    }
    /// External owner/test awaits shutdown, including any pending send/receive cancellation.
    public func shutdown() async {
        stop(); let r = receiver, w = writer
        await r?.value; await w?.value; receiver = nil; writer = nil
    }
}
