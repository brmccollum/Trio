import Charts
import Foundation
import SwiftUI

struct ForecastView: ChartContent {
    let preprocessedData: [(id: UUID, forecast: Forecast, forecastValue: ForecastValue)]
    let minForecast: [Int]
    let maxForecast: [Int]
    let units: GlucoseUnits
    let maxValue: Decimal
    let forecastDisplayType: ForecastDisplayType
    let lastDeterminationDate: Date

    var body: some ChartContent {
        if OffworldTheme.isEnabled {
            if forecastDisplayType == .lines {
                drawOffworldLines()
            } else {
                drawOffworldCone()
            }
        } else if forecastDisplayType == .lines {
            drawForecastsLines()
        } else {
            drawForecastsCone()
        }
    }

    // MARK: - Off-world (theme on only). Same bounds, same values, same 2.5 hour limit as stock.

    private struct ConePoint {
        let index: Int
        let date: Date
        let low: Decimal
        let high: Decimal
    }

    /// The stock cone's bounds, point for point: a zero-width pair is widened by 1 mg/dL each way,
    /// values are converted to the user's unit and capped at the chart maximum.
    private var conePoints: [ConePoint] {
        let limit = Date(timeIntervalSinceNow: TimeInterval(hours: 2.5))
        return (0 ..< min(minForecast.count, maxForecast.count)).compactMap { index in
            let date = timeForIndex(Int32(index))
            guard date <= limit else { return nil }
            let isFlat = minForecast[index] == maxForecast[index]
            let rawLow = Decimal(isFlat ? minForecast[index] - 1 : minForecast[index])
            let rawHigh = Decimal(isFlat ? minForecast[index] + 1 : maxForecast[index])
            let low = units == .mgdL ? rawLow : rawLow.asMmolL
            let high = units == .mgdL ? rawHigh : rawHigh.asMmolL
            return ConePoint(index: index, date: date, low: min(low, maxValue), high: min(high, maxValue))
        }
    }

    /// The real forecast range as a soft band (no outline) that fades and tints violet toward the far
    /// end, and a wave that swings between the real lower and upper bound at each time. The band's
    /// outer extent is exactly the stock cone; the two inner layers only feather its edge.
    @ChartContentBuilder private func drawOffworldCone() -> some ChartContent {
        let points = conePoints
        let cyan = OffworldTheme.Swatch.cyan.color
        let violet = OffworldTheme.Swatch.violet.color
        // (share of the envelope's half-width, opacity near, opacity far)
        let layers: [(Double, Double, Double)] = [(1, 0.17, 0.08), (0.8, 0.07, 0.03), (0.55, 0.07, 0.03)]
        // cyan at the newest reading, through magenta, to a faded sunset orange at the far end
        let wave = LinearGradient(
            colors: [
                cyan.opacity(0.85),
                OffworldTheme.Swatch.magenta.color.opacity(0.7),
                OffworldTheme.Swatch.sunset.color.opacity(0.5)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )

        ForEach(Array(layers.enumerated()), id: \.offset) { layerIndex, layer in
            let style = LinearGradient(
                colors: [violet.opacity(layer.1), violet.opacity(layer.2)],
                startPoint: .leading,
                endPoint: .trailing
            )
            ForEach(points, id: \.index) { point in
                let middle = (point.low + point.high) / 2
                let half = (point.high - point.low) / 2 * Decimal(layer.0)
                AreaMark(
                    x: .value("Time", point.date),
                    yStart: .value("Min Value", layerIndex == 0 ? point.low : middle - half),
                    yEnd: .value("Max Value", layerIndex == 0 ? point.high : middle + half),
                    series: .value("Forecast", "cone-\(layerIndex)")
                )
                .foregroundStyle(style)
                .interpolationMethod(.catmullRom)
            }
        }

        if let first = points.first {
            let samples = OffworldForecastWave.samples(
                low: points.map { NSDecimalNumber(decimal: $0.low).doubleValue },
                high: points.map { NSDecimalNumber(decimal: $0.high).doubleValue }
            )
            ForEach(samples, id: \.id) { sample in
                LineMark(
                    x: .value("Time", first.date.addingTimeInterval(sample.offset)),
                    y: .value("Value", Decimal(sample.value)),
                    series: .value("Forecast", "cone-wave")
                )
                .foregroundStyle(wave)
                .lineStyle(StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// The four oref curves in violet (IOB), gold (COB), chrome (UAM) and pink (ZT), each with a soft halo.
    @ChartContentBuilder private func drawOffworldLines() -> some ChartContent {
        ForEach(preprocessedData, id: \.forecastValue.objectID) { tuple in
            let forecastValue = tuple.forecastValue
            let type = tuple.forecast.type ?? ""
            let valueAsDecimal = Decimal(forecastValue.value)
            let displayValue = units == .mmolL ? valueAsDecimal.asMmolL : valueAsDecimal
            let xValue = timeForIndex(forecastValue.index)
            let color = OffworldTheme.forecastLineColor(type: type)

            if xValue <= Date(timeIntervalSinceNow: TimeInterval(hours: 2.5)) {
                LineMark(
                    x: .value("Time", xValue),
                    y: .value("Value", displayValue),
                    series: .value("Forecast", "glow-" + type)
                )
                .foregroundStyle(color.opacity(0.18))
                .lineStyle(StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                LineMark(
                    x: .value("Time", xValue),
                    y: .value("Value", displayValue),
                    series: .value("Forecast", type)
                )
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func timeForIndex(_ index: Int32) -> Date {
        let currentTime = lastDeterminationDate
        let timeInterval = TimeInterval(index * 300)
        return currentTime.addingTimeInterval(timeInterval)
    }

    private func drawForecastsCone() -> some ChartContent {
        // Draw AreaMark for the forecast bounds
        ForEach(0 ..< max(minForecast.count, maxForecast.count), id: \.self) { index in
            if index < minForecast.count, index < maxForecast.count {
                let yMinMaxDelta = Decimal(minForecast[index] - maxForecast[index])
                let xValue = timeForIndex(Int32(index))

                // if distance between respective min and max is 0, provide a default range
                if yMinMaxDelta == 0 {
                    let yMinValue = units == .mgdL ? Decimal(minForecast[index] - 1) :
                        Decimal(minForecast[index] - 1)
                        .asMmolL
                    let yMaxValue = units == .mgdL ? Decimal(minForecast[index] + 1) :
                        Decimal(minForecast[index] + 1)
                        .asMmolL

                    if xValue <= Date(timeIntervalSinceNow: TimeInterval(hours: 2.5)) {
                        AreaMark(
                            x: .value("Time", xValue),
                            // maxValue is already parsed to user units, no need to parse
                            yStart: .value("Min Value", yMinValue <= maxValue ? yMinValue : maxValue),
                            yEnd: .value("Max Value", yMaxValue <= maxValue ? yMaxValue : maxValue)
                        )
                        .foregroundStyle(Color.blue.opacity(0.5))
                        .interpolationMethod(.catmullRom)
                    }
                } else {
                    let yMinValue = units == .mgdL ? Decimal(minForecast[index]) : Decimal(minForecast[index])
                        .asMmolL
                    let yMaxValue = units == .mgdL ? Decimal(maxForecast[index]) : Decimal(maxForecast[index])
                        .asMmolL

                    if xValue <= Date(timeIntervalSinceNow: TimeInterval(hours: 2.5)) {
                        AreaMark(
                            x: .value("Time", xValue),
                            // maxValue is already parsed to user units, no need to parse
                            yStart: .value("Min Value", yMinValue <= maxValue ? yMinValue : maxValue),
                            yEnd: .value("Max Value", yMaxValue <= maxValue ? yMaxValue : maxValue)
                        )
                        .foregroundStyle(Color.blue.opacity(0.5))
                        .interpolationMethod(.catmullRom)
                    }
                }
            }
        }
    }

    private func drawForecastsLines() -> some ChartContent {
        ForEach(preprocessedData, id: \.forecastValue.objectID) { tuple in
            let forecastValue = tuple.forecastValue
            let forecast = tuple.forecast
            let valueAsDecimal = Decimal(forecastValue.value)
            let displayValue = units == .mmolL ? valueAsDecimal.asMmolL : valueAsDecimal
            let xValue = timeForIndex(forecastValue.index)

            if xValue <= Date(timeIntervalSinceNow: TimeInterval(hours: 2.5)) {
                LineMark(
                    x: .value("Time", xValue),
                    y: .value("Value", displayValue)
                )
                .foregroundStyle(by: .value("Predictions", forecast.type ?? ""))
            }
        }
    }
}
