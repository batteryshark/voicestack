import Foundation

public enum PrincipalError {
    public static func message(_ detail: String?, captureRunning: Bool) -> String? {
        guard let detail, !detail.isEmpty else { return nil }
        if detail == RouteRecoveryNotice.paused { return detail }
        if detail == RouteSwitchError.unavailable.localizedDescription || detail == RouteSwitchError.failed.localizedDescription { return detail }
        if detail.hasPrefix("Speech service at ") { return detail }
        let text = detail.lowercased()
        if text.hasPrefix("notification:") { return "Couldn't open that message. Check History or try again." }
        if text.hasPrefix("speech:") { return "Some reply audio could not finish. The full reply is available to read." }
        if text.hasPrefix("recognition:") { return "Listening was interrupted. Check your words before sending." }
        if text.hasPrefix("message:") { return "Couldn't confirm the message was sent. Check History before trying again." }
        if text.hasPrefix("history:") { return "History couldn't load. Try again when connected." }
        if text.hasPrefix("reply:") { return "Couldn't confirm the reply stopped. Check the conversation before trying again." }
        if text == "connection lost" || ["network:", "network connection lost", "the network connection was lost", "could not connect to the server", "network is unreachable"].contains(where: text.hasPrefix) {
            return captureRunning ? nil : "Connection lost"
        }
        if text.contains("expired") || text.contains("unavailable") { return "This item is no longer available. Check History or try again." }
        if text.contains("microphone access") { return "Allow microphone access in iPhone Settings to use voice." }
        if text.contains("capture") || text.contains("microphone") { return "Microphone stopped. Try Start voice again." }
        if text.contains("referenced message") { return "That message is unavailable. Showing the conversation instead." }
        if text.contains("end the call") { return "End this call before changing conversations." }
        return "Couldn't complete that. Try again, or check Diagnostics in Settings."
    }
}
