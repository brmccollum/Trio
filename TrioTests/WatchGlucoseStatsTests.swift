import Foundation
import Testing

@testable import Trio

/// Tests for the display-only "today" summary sent to the watch stats page, and for the rule
/// that an empty placeholder state is never sent. Pure: no storage, no session, fixed clock.
@Suite("Watch glucose stats tests") struct WatchGlucoseStatsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    @Test("No readings gives dashes everywhere") func emptyGivesDashes() {
        let stats = WatchGlucoseStats.compute(values: [], units: .mgdL)
        #expect(stats == WatchGlucoseStats())
        #expect(stats.timeInRange == "--")
        #expect(stats.average == "--")
        #expect(stats.percentLow == "--")
        #expect(stats.highest == "--")
        #expect(stats.lowest == "--")
    }

    @Test("Percentages, average, highest and lowest in mg/dL") func basicMgdL() {
        // 10 readings: 1 low (60), 7 in range, 2 high (200, 250)
        let values = [60, 70, 100, 100, 110, 120, 150, 180, 200, 250]
        let stats = WatchGlucoseStats.compute(values: values, units: .mgdL)
        #expect(stats.timeInRange == "70%")
        #expect(stats.percentLow == "10%")
        #expect(stats.average == "134")
        #expect(stats.highest == "250")
        #expect(stats.lowest == "60")
    }

    @Test("70 and 180 count as in range; 69 is low; 181 is not in range") func boundaries() {
        #expect(WatchGlucoseStats.compute(values: [70, 180], units: .mgdL).timeInRange == "100%")
        #expect(WatchGlucoseStats.compute(values: [70, 180], units: .mgdL).percentLow == "0%")
        #expect(WatchGlucoseStats.compute(values: [69, 100], units: .mgdL).percentLow == "50%")
        #expect(WatchGlucoseStats.compute(values: [181, 100], units: .mgdL).timeInRange == "50%")
        #expect(WatchGlucoseStats.compute(values: [181, 100], units: .mgdL).percentLow == "0%")
    }

    @Test("One low in a full day is never rounded away") func rareLowStaysVisible() {
        let values = [65] + Array(repeating: 110, count: 287)
        let stats = WatchGlucoseStats.compute(values: values, units: .mgdL)
        #expect(stats.percentLow == "<1%")
        #expect(stats.timeInRange == "99%")
        #expect(stats.lowest == "65")
    }

    @Test("Average rounds to a whole number in mg/dL") func averageRounds() {
        #expect(WatchGlucoseStats.compute(values: [100, 101], units: .mgdL).average == "101")
        #expect(WatchGlucoseStats.compute(values: [100, 100, 101], units: .mgdL).average == "100")
    }

    @Test("mmol/L strings use the app's own conversion; percentages do not change") func mmol() {
        let stats = WatchGlucoseStats.compute(values: [54, 90, 108, 198], units: .mmolL)
        #expect(stats.timeInRange == "50%")
        #expect(stats.percentLow == "25%")
        #expect(stats.highest == Decimal(198).formattedAsMmolL)
        #expect(stats.lowest == Decimal(54).formattedAsMmolL)
        #expect(stats.average == (Decimal(450) / Decimal(4)).formattedAsMmolL)
        #expect(stats.highest != "198")
    }

    @Test("Only readings from local midnight to now are counted") func todayWindow() {
        let now = date(23, 14)
        let readings: [(date: Date, glucose: Int)] = [
            (date(22, 23, 55), 300), // yesterday: ignored
            (date(23, 0, 0), 100), // exactly midnight: counted
            (date(23, 9), 60),
            (date(23, 13, 55), 140),
            (date(23, 14, 5), 400), // after now: ignored
            (date(23, 10), 0) // not a reading: ignored
        ]
        let stats = WatchGlucoseStats.today(readings: readings, now: now, calendar: calendar, units: .mgdL)
        #expect(stats.highest == "140")
        #expect(stats.lowest == "60")
        #expect(stats.average == "100")
        #expect(stats.timeInRange == "67%")
        #expect(stats.percentLow == "33%")
    }

    @Test("Nothing today gives dashes even when yesterday has data") func nothingToday() {
        let stats = WatchGlucoseStats.today(
            readings: [(date(22, 12), 120)],
            now: date(23, 0, 5),
            calendar: calendar,
            units: .mgdL
        )
        #expect(stats == WatchGlucoseStats())
    }

    @Test("A bare WatchState is a placeholder; a built one is not") func placeholder() {
        #expect(WatchState(date: Date()).isPlaceholder)

        var built = WatchState(date: Date())
        built.lastLoopTime = "--"
        #expect(!built.isPlaceholder)
    }

    @Test("New fields default to nil and take part in equality") func newFields() {
        let now = Date()
        var a = WatchState(date: now)
        let b = WatchState(date: now)
        #expect(a.todayTimeInRange == nil)
        #expect(a == b)
        a.todayTimeInRange = "80%"
        #expect(a != b)
    }
}
