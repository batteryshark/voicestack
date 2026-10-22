import Foundation

/// Main-queue one-shot write completion. Cancellation releases a waiter without inventing a write success.
final class RecognitionEndTransmission {
    private var result: Result<ContinuousClock.Instant, Error>?
    private var waiters: [UUID: CheckedContinuation<ContinuousClock.Instant, Error>] = [:]

    func resolve(_ result: Result<ContinuousClock.Instant, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = waiters; waiters = [:]
        for waiter in pending.values { waiter.resume(with: result) }
    }

    @MainActor func value() async throws -> ContinuousClock.Instant {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result) }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }
}
