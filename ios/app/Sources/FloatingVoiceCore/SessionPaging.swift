import Foundation

public struct SessionPage: Equatable, Sendable {
    public let sessions: [SessionSummary]
    public let nextCursor: String?
    public init(sessions: [SessionSummary], nextCursor: String? = nil) {
        self.sessions = sessions; self.nextCursor = nextCursor
    }
    public static func validCursor(_ cursor: String) -> Bool {
        !cursor.isEmpty && cursor.utf8.count <= 1024 && cursor.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

/// Picker-owned paging: coalesces scroll triggers and fences stale refresh results.
public struct SessionPaging: Sendable {
    public struct Request: Equatable, Sendable {
        fileprivate let id = UUID()
        public let cursor: String?
    }
    public private(set) var sessions: [SessionSummary] = []
    public private(set) var hasMore = true
    public private(set) var error: String?
    public var loading: Bool { pending != nil }
    public private(set) var nextCursor: String?
    private var seen: Set<String> = []
    private var pending: Request?
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func begin() -> Request? {
        guard !loading, hasMore else { return nil }
        let request = Request(cursor: nextCursor)
        pending = request; error = nil
        return request
    }
    public mutating func complete(_ request: Request, page: SessionPage) {
        guard pending == request else { return }
        if let next = page.nextCursor, !SessionPage.validCursor(next) || next == request.cursor || seen.contains(next) {
            fail(request, message: "Session paging did not advance. Refresh the picker.")
            return
        }
        if let cursor = request.cursor { seen.insert(cursor) }
        var byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for session in page.sessions { byID[session.id] = session }
        sessions = byID.values.sorted { $0.updated == $1.updated ? $0.id < $1.id : $0.updated > $1.updated }
        nextCursor = page.nextCursor; hasMore = nextCursor != nil; pending = nil
    }
    public mutating func fail(_ request: Request, message: String) {
        guard pending == request else { return }
        pending = nil; error = message
    }
}
