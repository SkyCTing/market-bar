import AppKit
import XCTest
@testable import MarketBar

final class GoldTrendTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(_ minute: Int, _ price: Double, provider: GoldProvider = .zheShang) -> GoldHistorySample {
        GoldHistorySample(provider: provider, sampledAt: start.addingTimeInterval(TimeInterval(minute * 60)), price: price)
    }

    func testCalendarRangesAndCustomValidation() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 20)))
        let day = try GoldTrendRange.day.dates(now: now, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day], from: day.0).day, 27)
        let week = try GoldTrendRange.week.dates(now: now, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day], from: week.0).day, 21)
        let month = try GoldTrendRange.month.dates(now: now, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.month, .day], from: month.0).month, 8)
        XCTAssertEqual(calendar.dateComponents([.month, .day], from: month.0).day, 28)
        let quarter = try GoldTrendRange.threeMonths.dates(now: now, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.month], from: quarter.0).month, 6)
        let customStart = now.addingTimeInterval(-86_400)
        XCTAssertEqual(try GoldTrendRange.custom.dates(now: now, customStart: customStart, customEnd: now).0, customStart)
        XCTAssertThrowsError(try GoldTrendRange.custom.dates(now: now, customStart: now, customEnd: customStart))
        XCTAssertThrowsError(try GoldTrendRange.custom.dates(now: now, customStart: start, customEnd: start.addingTimeInterval(367 * 86_400)))
    }

    func testExtremaAreExactEvenAfterDownsampling() {
        var samples = (0..<5_000).map { sample($0, 1_000 + Double($0 % 17)) }
        samples[1_281] = sample(1_281, 1_150)
        samples[3_817] = sample(3_817, 850)
        let trend = GoldTrend(provider: .zheShang, start: start,
                              end: start.addingTimeInterval(5_000 * 60), samples: samples)
        XCTAssertEqual(trend.high, samples[1_281])
        XCTAssertEqual(trend.low, samples[3_817])
        let drawing = trend.drawingSamples(buckets: 250)
        XCTAssertTrue(drawing.contains(samples[1_281]))
        XCTAssertTrue(drawing.contains(samples[3_817]))
        XCTAssertLessThan(drawing.count, 1_100)
        XCTAssertEqual(drawing.first, samples.first)
        XCTAssertEqual(drawing.last, samples.last)
    }

    func testOfflineGapIsNotConnectedEvenWhenDownsampled() {
        let samples = (0..<2_000).map { sample($0, 1_000) }
            + (0..<2_000).map { sample($0 + 4_000, 1_200) }
        let trend = GoldTrend(provider: .minSheng, start: start,
                              end: start.addingTimeInterval(6_000 * 60), samples: samples)
        let segments = trend.drawingSegments(buckets: 80)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].last?.sampledAt, samples[1_999].sampledAt)
        XCTAssertEqual(segments[1].first?.sampledAt, samples[2_000].sampledAt)
        XCTAssertFalse(GoldTrend.joins(samples[1_999], samples[2_000]))
        XCTAssertTrue(GoldTrend.joins(samples[0], samples[1]))
        XCTAssertFalse(GoldTrend.joins(sample(0, 1_000), sample(2, 1_001)),
                       "A missing capture minute must not be drawn as a continuous quote")
        let nearBoundary = GoldHistorySample(
            provider: .zheShang, sampledAt: samples[0].sampledAt.addingTimeInterval(121), price: 1_001
        )
        XCTAssertFalse(GoldTrend.joins(samples[0], nearBoundary))
    }

    func testNearestSampleUsesActualTimeNotInterpolatedPrice() {
        let samples = [sample(0, 1_000), sample(30, 1_050), sample(80, 990)]
        let trend = GoldTrend(provider: .zheShang, start: start,
                              end: start.addingTimeInterval(80 * 60), samples: samples)
        XCTAssertEqual(trend.nearest(to: start.addingTimeInterval(22 * 60)), samples[1])
        XCTAssertEqual(trend.nearest(to: start.addingTimeInterval(7 * 60)), samples[0])
        XCTAssertEqual(trend.nearest(to: start.addingTimeInterval(100 * 60)), samples[2])
        XCTAssertNil(GoldTrend(provider: .zheShang, start: start, end: start, samples: []).nearest(to: start))
    }

    func testThreeMonthsOfSparseSamplesKeepChartDrawingBounded() {
        let samples = (0..<65_000).map { sample($0 * 2, 1_000 + Double($0 % 31) / 10) }
        let trend = GoldTrend(
            provider: .zheShang, start: start,
            end: start.addingTimeInterval(130_000 * 60), samples: samples
        )
        let segments = trend.drawingSegments(buckets: 720)
        let rendered = segments.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(rendered, 720 * 4 + 4)
        XCTAssertTrue(segments.allSatisfy { $0.count == 1 },
                      "Missing minutes cannot be connected even when plotting a long range")
        XCTAssertEqual(trend.high?.price, 1_003)
        XCTAssertEqual(trend.low?.price, 1_000)
    }
}

@MainActor
final class GoldTrendWindowTests: XCTestCase {
    func testWindowShowsProviderSpecificExtremaAndEmptyState() async throws {
        _ = NSApplication.shared
        let base = Date()
        let samples = [
            GoldHistorySample(provider: .zheShang, sampledAt: base.addingTimeInterval(-1_200), price: 1_010.20),
            GoldHistorySample(provider: .zheShang, sampledAt: base.addingTimeInterval(-1_140), price: 1_022.40),
            GoldHistorySample(provider: .zheShang, sampledAt: base.addingTimeInterval(-1_080), price: 1_005.60),
        ]
        let controller = GoldTrendWindowController { provider, start, end in
            GoldTrend(provider: provider, start: start, end: end,
                      samples: provider == .zheShang ? samples : [])
        }
        defer { controller.close() }
        controller.show(provider: .zheShang)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "金价走势" })
        let content = try XCTUnwrap(window.contentView)
        let chart = try XCTUnwrap(content.subviews.compactMap { $0 as? GoldTrendChart }.first)
        let labels = content.subviews.compactMap { $0 as? NSTextField }
        let summary = try XCTUnwrap(labels.first { $0.stringValue.contains("正在读取") })
        for _ in 0..<40 {
            if summary.stringValue.contains("最高") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(summary.stringValue.contains("最高 ¥1022.40"))
        XCTAssertTrue(summary.stringValue.contains("最低 ¥1005.60"))
        XCTAssertEqual(chart.trend?.samples, samples)

        let picker = try XCTUnwrap(content.subviews.compactMap { $0 as? NSPopUpButton }.first)
        picker.selectItem(at: 1)
        _ = NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker)
        for _ in 0..<40 {
            if summary.stringValue.contains("暂无") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(chart.trend?.provider, .minSheng)
        XCTAssertTrue(summary.stringValue.contains("暂无"))
    }

    func testCustomDatesAndHoverShowActualSampleNotAnInterpolatedPrice() async throws {
        _ = NSApplication.shared
        let now = Date()
        let sample = GoldHistorySample(provider: .minSheng, sampledAt: now.addingTimeInterval(-1_200), price: 1_017.80)
        let controller = GoldTrendWindowController { provider, start, end in
            GoldTrend(provider: provider, start: start, end: end,
                      samples: provider == .minSheng && start <= sample.sampledAt && sample.sampledAt <= end ? [sample] : [])
        }
        defer { controller.close() }
        controller.show(provider: .minSheng)
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "金价走势" })
        let root = try XCTUnwrap(window.contentView)
        let chart = try XCTUnwrap(root.subviews.compactMap { $0 as? GoldTrendChart }.first)
        let segment = try XCTUnwrap(root.subviews.compactMap { $0 as? NSSegmentedControl }.first)
        let dates = root.subviews.compactMap { $0 as? NSDatePicker }
        XCTAssertEqual(dates.count, 2)
        XCTAssertTrue(dates.allSatisfy(\.isHidden))
        segment.selectedSegment = GoldTrendRange.custom.rawValue
        _ = NSApp.sendAction(try XCTUnwrap(segment.action), to: segment.target, from: segment)
        XCTAssertFalse(dates.contains { $0.isHidden })
        dates[0].dateValue = now.addingTimeInterval(-2 * 3_600)
        dates[1].dateValue = now
        _ = NSApp.sendAction(try XCTUnwrap(dates[1].action), to: dates[1].target, from: dates[1])
        for _ in 0..<40 {
            if chart.trend?.samples == [sample] { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(chart.trend?.samples, [sample])
        root.layoutSubtreeIfNeeded()
        let trend = try XCTUnwrap(chart.trend)
        let x = 66 + (chart.bounds.width - 88)
            * CGFloat(sample.sampledAt.timeIntervalSince(trend.start) / trend.end.timeIntervalSince(trend.start))
        let inside = chart.convert(NSPoint(x: x, y: chart.bounds.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: inside, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
        chart.mouseMoved(with: event)
        XCTAssertEqual(chart.hovered, sample)
        let labels = root.subviews.compactMap { $0 as? NSTextField }
        XCTAssertTrue(labels.contains { $0.stringValue.contains("¥1017.80 / 克") })

        dates[0].dateValue = now.addingTimeInterval(-367 * 86_400)
        _ = NSApp.sendAction(try XCTUnwrap(dates[0].action), to: dates[0].target, from: dates[0])
        XCTAssertNil(chart.trend)
        XCTAssertTrue(labels.contains { $0.stringValue.contains("不能超过一年") })
    }
}
