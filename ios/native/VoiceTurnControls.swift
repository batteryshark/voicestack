import Foundation

/// Presentation-only projection of the owning controller; no duplicated turn policy.
@MainActor struct VoiceTurnControls {
    let canBargeIn: Bool
    let halfDuplex: Bool
    let listeningSuppressed: Bool
    let sendDeadlineMs: Double?
    var bargeIn: (() -> Void)?
    init(status: ConversationController.Status, bargeIn: (() -> Void)?) {
        canBargeIn = status.canBargeIn
        halfDuplex = status.halfDuplex
        listeningSuppressed = status.listeningSuppressed
        sendDeadlineMs = status.sendCountdown?.deadlineMs
        self.bargeIn = bargeIn
    }
}
