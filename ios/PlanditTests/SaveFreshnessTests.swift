import XCTest
@testable import Plandit

/// SP-19: a save that's probably over (a pop-up whose date has passed, a "this weekend" post saved
/// weeks ago) isn't suggested.
final class SaveFreshnessTests: XCTestCase {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    @MainActor private func day(_ month: Int, _ day: Int, year: Int = 2026, hour: Int = 14) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @MainActor private func post(_ caption: String?, savedAt: Date, tags: [String] = []) -> SavedPost {
        SavedPost(
            url: URL(string: "https://www.tiktok.com/@test/video/1")!, platform: .tiktok, caption: caption,
            savedAt: savedAt, status: .ready,
            place: Place(name: "Spot", category: .shopping, neighborhood: "SoHo", address: "1 Spring St", latitude: 40.72, longitude: -74.0),
            tags: tags
        )
    }

    @MainActor private func isOver(_ post: SavedPost, on date: Date) -> Bool {
        SaveFreshness.isProbablyOver(post, now: date, calendar: Self.calendar)
    }

    @MainActor func testDateRangeThatHasPassedIsOver() {
        let popUp = post("Pop-up Nov 15–17", savedAt: day(11, 10))
        XCTAssertTrue(isOver(popUp, on: day(11, 21)))
        XCTAssertFalse(isOver(popUp, on: day(11, 16)), "still on during the range")
        XCTAssertFalse(isOver(popUp, on: day(11, 17, hour: 20)), "the last day isn't over until it ends")
    }

    @MainActor func testLaterDateIsNotOver() {
        let popUp = post("Pop-up until Dec 1", savedAt: day(11, 10))
        XCTAssertFalse(isOver(popUp, on: day(11, 21)))
        XCTAssertTrue(isOver(popUp, on: day(12, 2)))
    }

    @MainActor func testTemporaryWordsWithoutADateLastFourteenDays() {
        let sale = post("Sample sale this weekend", savedAt: day(11, 1))
        XCTAssertFalse(isOver(sale, on: day(11, 14)), "13 days after saving")
        XCTAssertTrue(isOver(sale, on: day(11, 16)), "15 days after saving")
    }

    @MainActor func testTemporaryWordsInTags() {
        let tagged = post("Matcha and merch", savedAt: day(11, 1), tags: ["Pop-up"])
        XCTAssertFalse(isOver(tagged, on: day(11, 14)))
        XCTAssertTrue(isOver(tagged, on: day(11, 16)))
        for words in ["Limited time menu", "Last day to see it", "One day only!", "Popup bakery", "pop up shop"] {
            XCTAssertTrue(isOver(post(words, savedAt: day(10, 1)), on: day(11, 21)), words)
        }
    }

    @MainActor func testOrdinaryCaptionNeverEnds() {
        let cookie = post("The cookie that's worth the line", savedAt: day(1, 2))
        XCTAssertFalse(isOver(cookie, on: day(11, 21)))
        XCTAssertFalse(isOver(post(nil, savedAt: day(1, 2)), on: day(11, 21)))
    }

    @MainActor func testTimesAloneAreNotDates() {
        XCTAssertFalse(isOver(post("Open until 9 PM, happy hour 5-7", savedAt: day(1, 2)), on: day(11, 21)))
        XCTAssertFalse(isOver(post("Free this weekend: walk the High Line", savedAt: day(11, 18)), on: day(11, 21)),
                       "a weekday or 'this weekend' isn't a date; the 14-day rule applies instead")
    }

    @MainActor func testDateWithoutAYearIsTheNextOneAfterSaving() {
        // Saved in December about January 5: next year's.
        let opening = post("Pop-up opens Jan 5", savedAt: day(12, 20))
        XCTAssertFalse(isOver(opening, on: day(1, 3, year: 2027)))
        XCTAssertTrue(isOver(opening, on: day(1, 6, year: 2027)))
        // Saved the day after the date it names: that's next year's, so not over yet.
        XCTAssertFalse(isOver(post("Pop-up Nov 15", savedAt: day(11, 16)), on: day(11, 21)))
    }

    @MainActor func testDateWithAYearIsTakenAsWritten() {
        XCTAssertTrue(isOver(post("Pop-up March 3, 2026 only", savedAt: day(11, 1)), on: day(11, 21)))
        XCTAssertFalse(isOver(post("Market on 12/5/2026", savedAt: day(11, 1)), on: day(11, 21)))
        // With a year, even a day ending in /10 is a date: December 10, 2026.
        let market = post("Market on 12/10/2026", savedAt: day(11, 1))
        XCTAssertFalse(isOver(market, on: day(12, 10, hour: 20)))
        XCTAssertTrue(isOver(market, on: day(12, 11, hour: 1)))
    }

    @MainActor func testResultFollowsTheCaption() {
        var edited = post("Pop-up Nov 15–17", savedAt: day(11, 10))
        XCTAssertTrue(isOver(edited, on: day(11, 21)))
        edited.caption = "Pop-up until Dec 1"
        XCTAssertFalse(isOver(edited, on: day(11, 21)), "the cache is per post and caption")
    }

    // MARK: - Numbers that look like dates

    @MainActor func testRatingsAreNotDates() {
        // Read as October 10 or September 10, these would stop a favorite being suggested.
        for caption in ["best pizza 10/10", "Best birria in Queens 10/10", "Rated 9/10", "Rated 9/10, would go again"] {
            XCTAssertFalse(isOver(post(caption, savedAt: day(8, 1)), on: day(11, 21)), caption)
            XCTAssertNil(SaveFreshness.facts(for: post(caption, savedAt: day(8, 1)), calendar: Self.calendar).lastDay, caption)
        }
    }

    @MainActor func testOpenAllHoursIsNotADate() {
        XCTAssertFalse(isOver(post("Diner, open 24/7", savedAt: day(6, 1)), on: day(11, 21)))
    }

    @MainActor func testNumericDateCountsForATemporarySave() {
        // Saved November 10 about November 15: over once the 15th ends, well before the 14-day rule.
        let popUp = post("Pop-up 11/15", savedAt: day(11, 10))
        XCTAssertFalse(isOver(popUp, on: day(11, 15, hour: 20)))
        XCTAssertTrue(isOver(popUp, on: day(11, 17)))
    }

    @MainActor func testNumericDateWithoutATemporaryWordDoesNotCount() {
        let market = post("Night market 11/15", savedAt: day(11, 10))
        XCTAssertFalse(isOver(market, on: day(11, 21)))
        XCTAssertFalse(isOver(market, on: day(3, 1, year: 2027)))
    }

    @MainActor func testRatingOnATemporarySaveFallsBackToFourteenDays() {
        // 10/10 isn't a date even here, so the 14-day rule decides.
        let popUp = post("Pop-up bakery, 10/10", savedAt: day(11, 1))
        XCTAssertFalse(isOver(popUp, on: day(11, 14)))
        XCTAssertTrue(isOver(popUp, on: day(11, 16)))
    }
}
