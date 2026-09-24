import Foundation
import XCTest

@testable import MarketBar

final class MarketCalendarTests: XCTestCase {
    private let calendar = TradingSession.calendar

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 10))!
    }

    // 2026-09-21 周一，09-25 周五，09-26 周六，10-01 国庆
    private let holidays = ["2026-10-01": "国庆节", "2026-10-02": "国庆节"]

    func testWeekdayIsTradingDayWithoutHoliday() {
        XCTAssertTrue(MarketCalendar.isTradingDay(date(2026, 9, 21), holidays: holidays))
        XCTAssertTrue(MarketCalendar.isTradingDay(date(2026, 9, 25), holidays: holidays))
    }

    func testWeekendIsNotTradingDay() {
        XCTAssertFalse(MarketCalendar.isTradingDay(date(2026, 9, 26), holidays: holidays))  // 周六
        XCTAssertFalse(MarketCalendar.isTradingDay(date(2026, 9, 27), holidays: holidays))  // 周日
    }

    func testHolidayIsNotTradingDay() {
        XCTAssertFalse(MarketCalendar.isTradingDay(date(2026, 10, 1), holidays: holidays))
        XCTAssertEqual(MarketCalendar.holidayName(on: date(2026, 10, 1), holidays: holidays), "国庆节")
    }

    /// 调休补班的周末：人要上班，但**股市照旧休市**
    func testMakeupWorkdayOnWeekendIsStillNotTradingDay() {
        // 2026-09-27 是周日（补班与否都不开盘）
        XCTAssertFalse(MarketCalendar.isTradingDay(date(2026, 9, 27), holidays: ["2026-09-27": "补班"]))
    }

    func testParsesHolidayPayload() throws {
        let json = """
        {"code":0,"holiday":{
          "10-01":{"holiday":true,"name":"国庆节","date":"2026-10-01"},
          "10-10":{"holiday":false,"name":"国庆节后补班","date":"2026-10-10"},
          "01-01":{"holiday":true,"name":"元旦","date":"2026-01-01"}}}
        """
        let parsed = MarketCalendar.parseHolidays(Data(json.utf8))

        XCTAssertEqual(parsed["2026-10-01"], "国庆节")
        XCTAssertEqual(parsed["2026-01-01"], "元旦")
        XCTAssertNil(parsed["2026-10-10"], "补班日不是放假，不能算进节假日")
    }

    func testParseHolidaysToleratesGarbage() {
        XCTAssertTrue(MarketCalendar.parseHolidays(Data()).isEmpty)
        XCTAssertTrue(MarketCalendar.parseHolidays(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(MarketCalendar.parseHolidays(Data(#"{"code":1}"#.utf8)).isEmpty)
    }

    func testHolidayCacheRoundTrip() throws {
        let suiteName = "MarketCalendarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        MarketCalendar.HolidayCache.save(["2026-10-01": "国庆节"], year: 2026, to: defaults)

        XCTAssertEqual(MarketCalendar.HolidayCache.load(year: 2026, from: defaults)["2026-10-01"], "国庆节")
        XCTAssertTrue(MarketCalendar.HolidayCache.load(year: 2027, from: defaults).isEmpty)
        XCTAssertEqual(MarketCalendar.HolidayCache.year(of: date(2026, 10, 1)), 2026)
    }

    func testGreetingOnWeekendAndHoliday() {
        let weekend = MarketClosedGreeting.lines(for: date(2026, 9, 26), holidayName: nil)
        XCTAssertEqual(weekend.headline, "周末愉快")
        XCTAssertTrue(MarketClosedGreeting.greetings.contains(weekend.greeting))

        let holiday = MarketClosedGreeting.lines(for: date(2026, 10, 1), holidayName: "国庆节")
        XCTAssertEqual(holiday.headline, "国庆节")
        XCTAssertEqual(holiday.greeting, "节日快乐")
    }

    /// 同一天多次调用结果必须一致（否则牌子上的问候语会闪）
    func testGreetingIsStableWithinTheSameDay() {
        let first = MarketClosedGreeting.lines(for: date(2026, 9, 26), holidayName: nil)
        let second = MarketClosedGreeting.lines(for: date(2026, 9, 26), holidayName: nil)
        XCTAssertEqual(first.greeting, second.greeting)
    }
}
