import Foundation

/// Terminal calls may not receive another scene notification (e.g. lock-screen End).
/// Reuse the existing suspension path, which retains drafts before invalidating the lease.
@MainActor public enum CallSceneReconciler {
    public static func reconcile(hasCall: Bool, foreground: Bool, protectedDataAvailable: Bool, suspend: () -> Void) {
        if !hasCall && (!foreground || !protectedDataAvailable) { suspend() }
    }
}
