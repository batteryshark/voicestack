import Foundation
import Testing
@testable import FloatingVoiceCore

@Suite struct HistoryAnchorTests {
    private func record(_ id: String, _ type: String = "assistant", parts: [[String: Any]] = [["type":"text","text":"Visible reply."]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["id":id,"type":type,"content":parts])
    }
    @Test func oldToolRowRetainsItsOwnStableAnchorAmongLongVariedHistory() throws {
        var records = (0..<160).map { record("m\($0)", parts:[["type":"text","text":String(repeating:"Long paragraph. ",count:1+$0%15)]]) }
        records[3] = record("tool", parts:[["type":"tool","state":["status":"completed","content":[]]]])
        let anchor = try #require(HistoryAnchor.resolve("tool",records:records))
        #expect(anchor.sourceID == "tool" && anchor.rowID == "tool" && anchor.kind == .work)
    }
    @Test func hiddenAndEmptyRecordsResolveToNearestVisibleNeighbourNotLatest() throws {
        let records = [record("before"),record("hidden","idle"),record("empty",parts:[["type":"text","text":"  \n"]]),record("after"),record("latest")]
        #expect(HistoryAnchor.resolve("hidden",records:records)?.rowID == "before")
        #expect(HistoryAnchor.resolve("empty",records:records)?.rowID == "after")
        #expect(HistoryAnchor.resolve("missing",records:records) == nil)
        #expect(HistoryAnchor.resolve("empty",records:[records[2]]) == nil)
    }
    @Test func collapsedWorkAnchorTakesPrecedenceOverAnAdjacentMessage() {
        let records = [record("work"),record("hidden","execution"),record("latest")]
        let anchor = HistoryAnchor.resolve("hidden",records:records,collapsed:["hidden":"work"])
        #expect(anchor?.rowID == "work" && anchor?.kind == .work)
    }
    @Test func viewportMustConfirmCorrectRequestAndVisibleHeaderAfterScroll() throws {
        let anchor = try #require(HistoryAnchor.resolve("target",records:[record("target")]))
        var nav = HistoryNavigation(); let request = nav.request(anchor,newestRow:"latest")
        let viewport = CGRect(x:0,y:0,width:400,height:600), visible = CGRect(x:16,y:25,width:368,height:24)
        nav.observedViewport(request:request,rowID:"target",rowFrame:visible,viewport:viewport)
        #expect(nav.confirmedRequest == nil) // Data/mounting alone is not proof.
        nav.requestedScroll(request)
        nav.observedViewport(request:UUID(),rowID:"target",rowFrame:visible,viewport:viewport)
        nav.observedViewport(request:request,rowID:"wrong",rowFrame:visible,viewport:viewport)
        nav.observedViewport(request:request,rowID:"target",rowFrame:CGRect(x:0,y:599,width:400,height:30),viewport:viewport)
        nav.observedViewport(request:request,rowID:"target",rowFrame:CGRect(x:0,y:-200,width:400,height:30),viewport:viewport)
        #expect(nav.confirmedRequest == nil)
        nav.observedViewport(request:request,rowID:"target",rowFrame:visible,viewport:viewport)
        #expect(nav.confirmedRequest == request && nav.pinned)
    }
    @Test func latestFollowRaceAndOlderPagingCannotReleasePinButUserOrNewTurnCan() throws {
        let anchor = try #require(HistoryAnchor.resolve("target",records:[record("target")]))
        var nav = HistoryNavigation(); _ = nav.request(anchor,newestRow:"latest")
        // An older-page merge or streaming detail update keeps the same newest ID.
        for _ in 0..<20 { nav.rowsChanged(newestRow:"latest"); #expect(!nav.allowsLatestFollow && nav.anchor == anchor) }
        nav.userScrolled(); #expect(nav.allowsLatestFollow && !nav.releasedByNewTurn)
        _ = nav.request(anchor,newestRow:"latest")
        nav.rowsChanged(newestRow:"new-turn")
        #expect(nav.allowsLatestFollow && nav.releasedByNewTurn)
    }
}
