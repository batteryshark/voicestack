import SwiftUI

/// Explicit launch-only inspection of the principal-owned throwaway. Never sends input itself.
enum CanvasDeviceProbe {
    static let session = "ses_example0000000000000000000"
    static let message = "msg_synthetic0001"
    static let view = "a513aa2d-c796-47e2-a4cf-6dea84ff9e53"
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-FVCanvas25Probe") }
    @MainActor static func run(_ model: PhoneModel) async {
        guard enabled, InstalledBuild.number == 25 else { return }
        do {
            let routed = try await model.canvasProbeGate.run(readiness: {
                .init(active: UIApplication.shared.applicationState == .active,
                      unlocked: UIApplication.shared.isProtectedDataAvailable,
                      paired: model.paired, preparing: model.connecting,
                      hasBackend: model.backend != nil, hasCall: model.hasCall)
            }) {
                let context = try ReachOutContext(record: ["reachoutID": "canvas25-probe", "session": session, "messageID": message, "expiry": Date().addingTimeInterval(300).timeIntervalSince1970 * 1000], reachoutID: "canvas25-probe")
                try await model.openReachOut(context, reviewBuild: false)
            }
            if routed { model.canvasProbeReady = true }
        } catch {
            // Separate from startup's transient error, which prepare() clears on success.
            model.canvasProbeError = "Canvas check stopped (\(NotificationRouteFailure.classify(error).rawValue)). No input was sent."
        }
    }
}

/// Also shown in History: viewport failures can happen after its sheet is presented.
struct CanvasProbeStatus: View {
    @ObservedObject var model: PhoneModel
    var body: some View {
        if let error = model.canvasProbeError {
            Text(error).font(.callout).padding(12).accessibilityIdentifier("canvas.probe.error")
        } else if model.canvasProbeReady {
            Text("Canvas check ready").font(.caption).padding(8).accessibilityIdentifier("canvas.probe.ready")
        }
    }
}
