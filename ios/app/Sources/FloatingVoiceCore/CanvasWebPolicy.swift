/// Shared constants make the security contract testable without WebKit or a live service.
public enum CanvasWebPolicy {
    public static let persistent = false
    public static let scripts = true
    public static let networkRules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]"#
}
