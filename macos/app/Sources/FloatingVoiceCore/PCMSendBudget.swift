/// Reviewed bounded transport admission from phone 152a394 NetworkPolicy.
public struct PCMSendBudget {
    private var count = 0, bytes = 0
    public init() {}
    public mutating func reserve(_ size: Int) -> Bool {
        guard size >= 0, count < 100, size <= 64000 - bytes else { return false }
        count += 1; bytes += size; return true
    }
    public mutating func release(_ size: Int) { count = max(0, count - 1); bytes = max(0, bytes - size) }
}
