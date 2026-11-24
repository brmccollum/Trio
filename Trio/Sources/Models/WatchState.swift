import Foundation
import SwiftUI

struct WatchState: Hashable, Equatable, Sendable, Encodable, Decodable {
    var date: Date
    var currentGlucose: String?
    var currentGlucoseColorString: String?
    var trend: String?
    var delta: String?
    var glucoseValues: [WatchGlucoseObject] = []
    var minYAxisValue: Decimal = 39.0
    var maxYAxisValue: Decimal = 200.0
    var units: GlucoseUnits = .mgdL
    var iob: String?
    var cob: String?
    var lastLoopTime: String?
    var overridePresets: [OverridePresetWatch] = []
    var tempTargetPresets: [TempTargetPresetWatch] = []

    // Safety limits
    var maxBolus: Decimal = 10.0
    var maxCarbs: Decimal = 250.0
    var maxFat: Decimal = 250.0
    var maxProtein: Decimal = 250.0

    // Pump specific dosing increment
    var bolusIncrement: Decimal = 0.05
    var confirmBolusFaster: Bool = false

    // Forecast options
    var showForecast: Bool = false
    var isForecastCone: Bool = false
    var forecastStartDate: Date? = nil
    var forecastConeMin: [Double] = []
    var forecastConeMax: [Double] = []
    var forecastLines: [String: [Double]] = [:] // "iob" / "cob" / "uam" / "zt" -> values

    /// Optional Off-world appearance flag for the watch. Display only.
    var offworldTheme: Bool = false

    /// Today's glucose summary for the watch stats page (local midnight to now). Display only.
    var todayTimeInRange: String?
    var todayAverageGlucose: String?
    var todayPercentLow: String?
    var todayHighestGlucose: String?
    var todayLowestGlucose: String?

    /// True for the bare `WatchState(date:)` that `setupWatchState` returns when it could not build a
    /// real state. A real state always carries `lastLoopTime`. Placeholders must never reach the watch.
    var isPlaceholder: Bool {
        lastLoopTime == nil && currentGlucose == nil && iob == nil
    }

    static func == (lhs: WatchState, rhs: WatchState) -> Bool {
        lhs.date == rhs.date &&
            lhs.currentGlucose == rhs.currentGlucose &&
            lhs.trend == rhs.trend &&
            lhs.delta == rhs.delta &&
            lhs.glucoseValues.count == rhs.glucoseValues.count &&
            zip(lhs.glucoseValues, rhs.glucoseValues).allSatisfy {
                $0.0.date == $0.1.date && $0.0.glucose == $0.1.glucose && $0.0.color == $0.1.color
            } &&
            lhs.minYAxisValue == rhs.minYAxisValue &&
            lhs.maxYAxisValue == rhs.maxYAxisValue &&
            lhs.units == rhs.units &&
            lhs.iob == rhs.iob &&
            lhs.cob == rhs.cob &&
            lhs.lastLoopTime == rhs.lastLoopTime &&
            lhs.overridePresets == rhs.overridePresets &&
            lhs.tempTargetPresets == rhs.tempTargetPresets &&
            lhs.maxBolus == rhs.maxBolus &&
            lhs.maxCarbs == rhs.maxCarbs &&
            lhs.maxFat == rhs.maxFat &&
            lhs.maxProtein == rhs.maxProtein &&
            lhs.bolusIncrement == rhs.bolusIncrement &&
            lhs.confirmBolusFaster == rhs.confirmBolusFaster &&
            lhs.showForecast == rhs.showForecast &&
            lhs.isForecastCone == rhs.isForecastCone &&
            lhs.forecastStartDate == rhs.forecastStartDate &&
            lhs.forecastConeMin == rhs.forecastConeMin &&
            lhs.forecastConeMax == rhs.forecastConeMax &&
            lhs.forecastLines == rhs.forecastLines &&
            lhs.offworldTheme == rhs.offworldTheme &&
            lhs.todayTimeInRange == rhs.todayTimeInRange &&
            lhs.todayAverageGlucose == rhs.todayAverageGlucose &&
            lhs.todayPercentLow == rhs.todayPercentLow &&
            lhs.todayHighestGlucose == rhs.todayHighestGlucose &&
            lhs.todayLowestGlucose == rhs.todayLowestGlucose
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(date)
        hasher.combine(currentGlucose)
        hasher.combine(trend)
        hasher.combine(delta)
        for value in glucoseValues {
            hasher.combine(value.date)
            hasher.combine(value.glucose)
            hasher.combine(value.color)
        }
        hasher.combine(minYAxisValue)
        hasher.combine(maxYAxisValue)
        hasher.combine(units)
        hasher.combine(iob)
        hasher.combine(cob)
        hasher.combine(lastLoopTime)
        hasher.combine(overridePresets)
        hasher.combine(tempTargetPresets)
        hasher.combine(maxBolus)
        hasher.combine(maxCarbs)
        hasher.combine(maxFat)
        hasher.combine(maxProtein)
        hasher.combine(bolusIncrement)
        hasher.combine(confirmBolusFaster)
        hasher.combine(showForecast)
        hasher.combine(isForecastCone)
        hasher.combine(forecastStartDate)
        hasher.combine(forecastConeMin)
        hasher.combine(forecastConeMax)
        hasher.combine(forecastLines)
        hasher.combine(offworldTheme)
        hasher.combine(todayTimeInRange)
        hasher.combine(todayAverageGlucose)
        hasher.combine(todayPercentLow)
        hasher.combine(todayHighestGlucose)
        hasher.combine(todayLowestGlucose)
    }
}

/// Today's glucose summary shown on the watch stats page. Display only, pure: no storage, no clock
/// of its own. Thresholds are fixed at 70 to 180 mg/dL; strings follow the user's units.
struct WatchGlucoseStats: Equatable {
    static let placeholder = "--"
    static let lowLimit = 70
    static let highLimit = 180

    var timeInRange: String = WatchGlucoseStats.placeholder
    var average: String = WatchGlucoseStats.placeholder
    var percentLow: String = WatchGlucoseStats.placeholder
    var highest: String = WatchGlucoseStats.placeholder
    var lowest: String = WatchGlucoseStats.placeholder

    /// - Parameters:
    ///   - readings: stored readings in mg/dL, any order; those outside local midnight...now are ignored.
    ///   - now: end of the window; the window starts at the local midnight before it.
    static func today(
        readings: [(date: Date, glucose: Int)],
        now: Date,
        calendar: Calendar = .current,
        units: GlucoseUnits
    ) -> WatchGlucoseStats {
        let startOfDay = calendar.startOfDay(for: now)
        let values = readings
            .filter { $0.date >= startOfDay && $0.date <= now && $0.glucose > 0 }
            .map(\.glucose)
        return compute(values: values, units: units)
    }

    /// - Parameter values: readings in mg/dL.
    static func compute(values: [Int], units: GlucoseUnits) -> WatchGlucoseStats {
        guard !values.isEmpty, let highest = values.max(), let lowest = values.min() else {
            return WatchGlucoseStats()
        }
        let count = values.count
        let inRange = values.filter { $0 >= lowLimit && $0 <= highLimit }.count
        let low = values.filter { $0 < lowLimit }.count

        // Never round a day with readings out of range up to 100 %, nor a day with lows down to 0 %.
        var inRangePercent = percent(inRange, of: count)
        if inRange < count { inRangePercent = min(inRangePercent, 99) }
        let lowPercent = percent(low, of: count)

        let mean = Decimal(values.reduce(0, +)) / Decimal(count)

        return WatchGlucoseStats(
            timeInRange: "\(inRangePercent)%",
            average: format(mean, units: units),
            percentLow: low > 0 && lowPercent == 0 ? "<1%" : "\(lowPercent)%",
            highest: format(Decimal(highest), units: units),
            lowest: format(Decimal(lowest), units: units)
        )
    }

    private static func percent(_ part: Int, of total: Int) -> Int {
        Int((Double(part) / Double(total) * 100).rounded())
    }

    private static func format(_ mgdL: Decimal, units: GlucoseUnits) -> String {
        units == .mgdL
            ? "\(Int(Double(truncating: mgdL as NSNumber).rounded()))"
            : mgdL.formattedAsMmolL
    }
}
