import XCTest
@testable import patternlock

@MainActor final class SpecialOfferTests: XCTestCase {
    private func storage() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        return calendar
    }

    func testAbsoluteDeadlineSurvivesDismissalRelaunchAndTimeAway() throws {
        let defaults = try storage(), now = Date()
        let offers = SpecialOfferStore(defaults: defaults)
        XCTAssertEqual(offers.remainingSeconds(at: now), 0)
        XCTAssertTrue(offers.begin(at: now, calendar: calendar))
        offers.dismiss()
        let restarted = SpecialOfferStore(defaults: defaults)
        XCTAssertEqual(restarted.remainingSeconds(at: now.addingTimeInterval(321)), 279)
        XCTAssertTrue(restarted.showsBanner(at: now.addingTimeInterval(321)))
        XCTAssertTrue(restarted.begin(at: now.addingTimeInterval(500), calendar: calendar))
        XCTAssertEqual(restarted.remainingSeconds(at: now.addingTimeInterval(500)), 100)
        XCTAssertEqual(restarted.remainingSeconds(at: now.addingTimeInterval(600)), 0)
        XCTAssertFalse(restarted.showsBanner(at: now.addingTimeInterval(601)))
        XCTAssertFalse(restarted.begin(at: now.addingTimeInterval(601), calendar: calendar))
    }

    func testDailyEligibilityUsesLocalMidnightButDoesNotRestartActiveWindow() throws {
        let offers = SpecialOfferStore(defaults: try storage())
        let beforeMidnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 23, minute: 58)))
        XCTAssertTrue(offers.begin(at: beforeMidnight, calendar: calendar))
        XCTAssertTrue(offers.begin(at: beforeMidnight.addingTimeInterval(180), calendar: calendar))
        XCTAssertEqual(offers.remainingSeconds(at: beforeMidnight.addingTimeInterval(180)), 420)
        XCTAssertTrue(offers.begin(at: beforeMidnight.addingTimeInterval(601), calendar: calendar))
        XCTAssertEqual(offers.remainingSeconds(at: beforeMidnight.addingTimeInterval(601)), 600)
        XCTAssertFalse(offers.begin(at: beforeMidnight.addingTimeInterval(1202), calendar: calendar))
    }

    func testBackwardClockCannotCreateAnotherWindow() throws {
        let now = Date(), offers = SpecialOfferStore(defaults: try storage())
        XCTAssertTrue(offers.begin(at: now, calendar: calendar))
        XCTAssertEqual(offers.remainingSeconds(at: now.addingTimeInterval(-1)), 0)
        XCTAssertFalse(offers.begin(at: now.addingTimeInterval(-86_400), calendar: calendar))
    }

    func testPurchaseEndsWindowWithoutMakingAnotherAvailableThatDay() throws {
        let now = Date(), defaults = try storage(), offers = SpecialOfferStore(defaults: defaults)
        XCTAssertTrue(offers.begin(at: now, calendar: calendar))
        offers.dismiss(); offers.end(at: now.addingTimeInterval(10))
        let restarted = SpecialOfferStore(defaults: defaults)
        XCTAssertFalse(restarted.showsBanner(at: now.addingTimeInterval(11)))
        XCTAssertFalse(restarted.begin(at: now.addingTimeInterval(11), calendar: calendar))
    }
}
