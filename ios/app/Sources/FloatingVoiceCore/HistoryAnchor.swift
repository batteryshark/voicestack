import Foundation

/// Source-message identity is independent of the display projection. A hidden
/// record still owns a position in source order; it never means "show latest".
public struct HistoryAnchor: Equatable, Sendable {
    public enum Kind: String, Sendable { case message, work, neighbour }
    public let sourceID: String
    public let rowID: String
    public let kind: Kind
    public static func resolve(_ sourceID: String, records: [Data], collapsed: [String: String] = [:]) -> Self? {
        let ids = records.map { ((try? JSONSerialization.jsonObject(with: $0)) as? [String: Any])?["id"] as? String }
        let rows = records.compactMap(MessageRow.init)
        let visible = Set(rows.map(\.id))
        guard let index = ids.firstIndex(of: sourceID) else { return nil }
        if let row = rows.first(where: { $0.id == sourceID }) {
            return Self(sourceID: sourceID, rowID: row.id, kind: row.text.isEmpty && row.steps > 0 ? .work : .message)
        }
        if let grouped = collapsed[sourceID], visible.contains(grouped) {
            return Self(sourceID: sourceID, rowID: grouped, kind: .work)
        }
        // Prefer the preceding row on an equal-distance tie. Never skip farther
        // into the conversation just because the newest row is already rendered.
        for distance in 1...max(1, ids.count) {
            for candidate in [index-distance, index+distance] where ids.indices.contains(candidate) {
                if let id = ids[candidate], visible.contains(id) {
                    return Self(sourceID: sourceID, rowID: id, kind: .neighbour)
                }
            }
        }
        return nil
    }
}

/// The same closed state machine drives native scrolling and regression tests.
/// A request cannot be acknowledged merely by locating data or mounting a row.
public struct HistoryNavigation: Equatable, Sendable {
    public private(set) var requestID: UUID?
    public private(set) var anchor: HistoryAnchor?
    public private(set) var confirmedRequest: UUID?
    public private(set) var scrollRequested = false
    public private(set) var releasedByNewTurn = false
    private var newestRow: String?
    public init() {}
    @discardableResult public mutating func request(_ anchor: HistoryAnchor, newestRow: String?) -> UUID {
        let id = UUID(); requestID = id; self.anchor = anchor; self.newestRow = newestRow
        confirmedRequest = nil; scrollRequested = false; releasedByNewTurn = false
        return id
    }
    public var pinned: Bool { anchor != nil }
    public var allowsLatestFollow: Bool { !pinned }
    public mutating func requestedScroll(_ request: UUID) {
        if requestID == request, pinned { scrollRequested = true }
    }
    public mutating func observedViewport(request: UUID, rowID: String, rowFrame: CGRect, viewport: CGRect) {
        guard requestID == request, anchor?.rowID == rowID, scrollRequested,
              Self.headerIsVisible(rowFrame, in: viewport) else { return }
        confirmedRequest = request
    }
    public static func headerIsVisible(_ rowFrame: CGRect, in viewport: CGRect) -> Bool {
        guard rowFrame.width > 0, rowFrame.height > 0, viewport.width > 0, viewport.height > 0 else { return false }
        let intersection = rowFrame.intersection(viewport)
        // Header/target marker, not a huge row's offscreen body. Require a
        // meaningful visible area instead of a one-pixel layout intersection.
        return !intersection.isNull && intersection.height >= min(20, rowFrame.height) && intersection.width >= min(40, rowFrame.width)
    }
    public mutating func userScrolled() { anchor = nil; releasedByNewTurn = false }
    public mutating func rowsChanged(newestRow: String?) {
        if pinned, let previous = self.newestRow, let newestRow, previous != newestRow { anchor = nil; releasedByNewTurn = true }
        self.newestRow = newestRow
    }
    public mutating func dismiss() { anchor = nil; releasedByNewTurn = false }
}
