/// Native repair owns resumption from BEFORE any synchronous admission callback
/// until the replacement graph is installed. An old running engine is not ready.
public struct PlaybackGraphRepairBarrier {
    public private(set) var inProgress = false
    private var generation = 0
    public init() {}
    @discardableResult public mutating func begin() -> Int {
        generation += 1; inProgress = true; return generation
    }
    @discardableResult public mutating func replacementInstalled(_ owner: Int) -> Bool {
        guard inProgress, generation == owner else { return false }
        inProgress = false; return true
    }
    public mutating func resetAfterClose() { generation += 1; inProgress = false }
}
