public enum CanvasSubmissionPolicy {
    public enum Failure: Equatable { case invalid, stale, unknown }
    public static func failure(status: Int?, admitted: Bool) -> Failure {
        guard !admitted else { return .unknown }
        if status == 400 || status == 413 { return .invalid }
        if status == 409 { return .stale }
        return .unknown
    }
}
