import Testing
@testable import FloatingVoiceCore

@Suite struct SessionPagingTests {
    private func row(_ n: Int, updated: Double? = nil) -> SessionSummary {
        SessionSummary(id: "ses_\(n)", title: "Session \(n)", updated: updated ?? Double(451-n))
    }
    private func begin(_ paging: inout SessionPaging) throws -> SessionPaging.Request {
        let request = paging.begin()
        return try #require(request)
    }
    @Test func scrollPages450NewestFirstAndCoalescesTriggers() throws {
        var paging = SessionPaging()
        for (start, end, next) in [(1,200,"page2"), (201,400,"page3"), (401,450,"")] {
            let request = try begin(&paging)
            let duplicate = paging.begin()
            #expect(paging.loading && duplicate == nil)
            paging.complete(request, page: SessionPage(sessions: (start...end).reversed().map { row($0) }, nextCursor: next.isEmpty ? nil : next))
        }
        #expect(paging.sessions == (1...450).map { row($0) })
        #expect(paging.sessions[299].id == "ses_300")
        let exhausted = paging.begin()
        #expect(!paging.loading && !paging.hasMore && exhausted == nil)
    }
    @Test func refreshFencesOldPagesAndErrorsWithoutBlockingReplacement() throws {
        var paging = SessionPaging()
        let stale = try begin(&paging); paging.reset()
        let fresh = try begin(&paging)
        paging.complete(stale, page: SessionPage(sessions: [row(1)]))
        paging.fail(stale, message: "old failure")
        #expect(paging.loading && paging.sessions.isEmpty && paging.error == nil)
        paging.complete(fresh, page: SessionPage(sessions: [row(2)]))
        #expect(paging.sessions == [row(2)] && !paging.loading)
    }
    @Test func retryRetainsRowsAndUsesSameCursorAndDeduplicatesOverlap() throws {
        var paging = SessionPaging()
        let first = try begin(&paging)
        paging.complete(first, page: SessionPage(sessions: [row(1)], nextCursor: "next"))
        let failed = try begin(&paging); paging.fail(failed, message: "offline")
        #expect(paging.sessions == [row(1)] && paging.error == "offline")
        let retry = try begin(&paging); #expect(retry.cursor == "next")
        paging.complete(retry, page: SessionPage(sessions: [row(1, updated: 900), row(2)]))
        #expect(paging.sessions.map(\.id) == ["ses_1", "ses_2"] && paging.sessions[0].updated == 900)
    }
    @Test func emptyPageWithCursorStillAdvancesAndCyclesFailVisibly() throws {
        var paging = SessionPaging()
        let first = try begin(&paging)
        paging.complete(first, page: SessionPage(sessions: [], nextCursor: "next"))
        #expect(paging.hasMore && paging.nextCursor == "next")
        let second = try begin(&paging)
        paging.complete(second, page: SessionPage(sessions: [], nextCursor: "next"))
        #expect(paging.error != nil && !paging.loading)
    }
    @Test func oldBridgeWithoutCursorIsSinglePage() throws {
        var paging = SessionPaging()
        let first = try begin(&paging)
        paging.complete(first, page: SessionPage(sessions: [row(1)]))
        let exhausted = paging.begin()
        #expect(!paging.hasMore && exhausted == nil)
    }
}
