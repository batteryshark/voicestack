import Foundation

public enum SpeechServiceError {
    public static func hostPort(_ url: String) -> String {
        guard let c = URLComponents(string: url), let host = c.host else { return url }
        return "\(host):\(c.port ?? (c.scheme == "https" || c.scheme == "wss" ? 443 : 80))"
    }
    public static func notRunning(_ url: String) -> String { "Speech service at \(hostPort(url)) isn't running" }
    public static func isFinal(_ message: String) -> Bool { message.hasPrefix("Speech service at ") || message.hasPrefix("Set \"") }
    public static func describe(url: String, error: Error) -> String {
        if let e = error as? ClientError, isFinal(e.message) { return e.message }
        if case HTTPError.noResponse = error { return notRunning(url) }
        if case let HTTPError.status(503, body) = error,
           let obj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
           obj["error"] as? String == "speech_unavailable",
           let service = obj["service"] as? String, ["asr", "tts"].contains(service),
           let endpoint = obj["endpoint"] as? String,
           endpoint.range(of: #"^[a-zA-Z0-9.\-]+:[0-9]{1,5}$"#, options: .regularExpression) != nil {
            return "Speech service at \(endpoint) isn't running"
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, [-1001, -1003, -1004, -1005, -1006, -1009].contains(ns.code) { return notRunning(url) }
        return "Speech service at \(hostPort(url)): \(error.localizedDescription)"
    }
}
