import Foundation

public enum CanvasDeliveryStatus: String, Sendable {
    case queued, sending, delivered, unsent, uncertain
    public init(hostStatus: String?) { self = hostStatus.flatMap(Self.init(rawValue:)) ?? .uncertain }
    public var pending: Bool { self == .queued || self == .sending }
    public var message: String {
        switch self {
        case .queued, .sending: return "Sending your input…"
        case .delivered: return "Input sent"
        case .unsent: return "Confirmed not sent. You can retry."
        case .uncertain: return "Delivery unknown · check History; not retried"
        }
    }
}

/// Only status reads occur here. Exhaustion is uncertainty, never proof of non-delivery.
@MainActor public enum CanvasDeliveryPolling {
    @discardableResult public static func run(initial: String?, budget: Int = 20,
        check: () throws -> Void,
        wait: () async throws -> Void = { try await Task.sleep(nanoseconds: 1_500_000_000) },
        fetchStatus: () async throws -> String?,
        observe: (CanvasDeliveryStatus) -> Void) async throws -> CanvasDeliveryStatus {
        var state = CanvasDeliveryStatus(hostStatus: initial)
        try Task.checkCancellation(); try check(); observe(state)
        for _ in 0..<max(0, budget) {
            guard state.pending else { return state }
            try await wait()
            try Task.checkCancellation(); try check()
            state = CanvasDeliveryStatus(hostStatus: try await fetchStatus())
            try Task.checkCancellation(); try check(); observe(state)
        }
        // Process the FINAL response before exhausting the budget: it may be delivered.
        if state.pending { state = .uncertain; observe(state) }
        return state
    }
}
