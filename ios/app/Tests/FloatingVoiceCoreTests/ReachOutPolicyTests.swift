import XCTest
@testable import FloatingVoiceCore

final class ReachOutPolicyTests: XCTestCase {
    private func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }

    func testDefaultsAndHalfOpenBoundaries() {
        let p = ReachOutPolicy(timeZone: "America/New_York")
        XCTAssertTrue(p.callsEnabled)
        for (instant, quiet) in [("2026-01-01T02:59:00Z", false), ("2026-01-01T03:00:00Z", true),
                                  ("2026-01-01T05:00:00Z", true), ("2026-01-01T13:59:00Z", true),
                                  ("2026-01-01T14:00:00Z", false)] {
            XCTAssertEqual(p.isQuiet(at: date(instant)), quiet)
        }
    }

    func testDSTAndTravel() {
        var p = ReachOutPolicy(quietStart: "01:00", quietEnd: "03:00", timeZone: "America/New_York")
        for instant in ["2026-03-08T06:59:00Z", "2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z"] {
            XCTAssertTrue(p.isQuiet(at: date(instant)))
        }
        XCTAssertFalse(p.isQuiet(at: date("2026-03-08T07:00:00Z")))
        p = ReachOutPolicy(timeZone: "America/New_York")
        let instant = date("2026-01-01T14:00:00Z")
        XCTAssertFalse(p.isQuiet(at: instant))
        p.timeZone = "Asia/Tokyo"
        XCTAssertTrue(p.isQuiet(at: instant))
    }

    func testFreshAcknowledgementAndVersioning() throws {
        let now = date("2026-01-01T17:00:00Z"), p = ReachOutPolicy(timeZone: "America/New_York")
        XCTAssertTrue(p.callsEligible(at: now, acknowledged: p, syncedAt: now))
        XCTAssertFalse(p.callsEligible(at: now, acknowledged: nil, syncedAt: now))
        XCTAssertFalse(p.callsEligible(at: now, acknowledged: p, syncedAt: now.addingTimeInterval(-86400)))
        var edited = p; edited.callsEnabled = false; edited.revision = 2
        XCTAssertFalse(edited.callsEligible(at: now, acknowledged: p, syncedAt: now))
        XCTAssertTrue(p.acceptsUpdate(edited)); XCTAssertFalse(edited.acceptsUpdate(p))
        XCTAssertEqual(try JSONDecoder().decode(ReachOutPolicy.self, from: JSONEncoder().encode(p)), p)
        edited.policyVersion = 99; XCTAssertFalse(edited.isValid)
        edited = p; edited.timeZone = "bad/zone"; XCTAssertTrue(edited.isQuiet(at: now))
        edited = p; edited.quietStart = "9:00"; XCTAssertFalse(edited.isValid)
    }
}
