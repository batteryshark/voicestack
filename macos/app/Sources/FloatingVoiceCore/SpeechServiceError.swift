import Foundation

/// User-facing wording for a speech service (recognition or speech). Voicestack never starts these services — they may
/// run elsewhere — so when one cannot be reached it says so plainly, and any other failure still names its host:port.
public enum SpeechServiceError {
    /// Once response audio starts, a timeout means the stream stalled, not that its listener isn't running
    /// or that model warm-up failed. Keep real connection failures and HTTP errors on the existing path.
    public static func describeStream(url: String, error: Error) -> String {
        if (error as? URLError)?.code == .timedOut {
            return "Speech service at \(hostPort(url)): audio stream stalled (timed out). Try again."
        }
        return describe(url: url, error: error)
    }
    /// The host and port of a configured URL, with the scheme's default port when none is written
    /// (e.g. "ws://127.0.0.1:8446/v1/transcribe" -> "127.0.0.1:8446").
    public static func hostPort(_ urlString: String) -> String {
        guard let c = URLComponents(string: urlString), let host = c.host, !host.isEmpty else { return urlString }
        let port = c.port ?? (c.scheme == "wss" || c.scheme == "https" ? 443 : 80)
        return "\(host):\(port)"
    }

    /// The plain wording for a service that cannot be reached. Exactly what the user sees.
    public static func notRunning(_ urlString: String) -> String {
        "Speech service at \(hostPort(urlString)) isn't running"
    }

    /// True when the failure is a connection-level one (refused, host unreachable, timeout, DNS) rather than a
    /// server that answered with an error status or a bad response.
    public static func isUnreachable(_ error: Error) -> Bool {
        if let e = error as? URLError, connectionCodes.contains(e.code) { return true }
        if let e = error as? HTTPError, case .noResponse = e { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, connectionCodes.contains(URLError.Code(rawValue: ns.code)) { return true }
        return false
    }

    private static let connectionCodes: Set<URLError.Code> = [
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut, .networkConnectionLost,
        .notConnectedToInternet, .cannotLoadFromNetwork, .resourceUnavailable, .secureConnectionFailed,
    ]

    /// True for a message that already carries its final wording (the plain wording, or a specific one naming the
    /// service), so it is not wrapped a second time.
    public static func isFinal(_ message: String) -> Bool {
        message.hasPrefix("Speech service at ") || message.hasPrefix("Set \"")
    }

    /// The user-facing message for a failed request: the plain wording when the service cannot be reached, a message
    /// that already names it, or `<host:port>: <detail>` for anything else (an HTTP status, a bad response).
    public static func describe(url urlString: String, error: Error) -> String {
        if let e = error as? ClientError, isFinal(e.message) { return e.message }
        if isUnreachable(error) { return notRunning(urlString) }
        return "Speech service at \(hostPort(urlString)): \(error.localizedDescription)"
    }
}
