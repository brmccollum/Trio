import Charts
import Foundation
import SwiftUI

struct GlucoseChartView: ChartContent {
    let glucoseData: [GlucoseStored]
    let units: GlucoseUnits
    let highGlucose: Decimal
    let lowGlucose: Decimal
    let currentGlucoseTarget: Decimal
    let isSmoothingEnabled: Bool
    let glucoseColorScheme: GlucoseColorScheme

    @ChartContentBuilder var body: some ChartContent {
        // The line's threshold colouring is defined for the static scheme; the dynamic scheme
        // (a per-reading gradient) keeps the stock dots.
        if OffworldTheme.isEnabled, glucoseColorScheme == .staticColor {
            drawOffworldGlucose()
        } else {
            drawGlucoseChart()
        }
    }

    /// Dynamic point color for a CGM reading. Manual readings render red and skip this.
    private func pointColor(for item: GlucoseStored) -> Color {
        // TODO: workaround for now: set low value to 55, to have dynamic color shades between 55 and user-set low (approx. 70); same for high glucose
        let hardCodedLow = Decimal(55)
        let hardCodedHigh = Decimal(220)
        let isDynamicColorScheme = glucoseColorScheme == .dynamicColor

        let stock = Trio.getDynamicGlucoseColor(
            glucoseValue: Decimal(item.glucose),
            highGlucoseColorValue: isDynamicColorScheme ? hardCodedHigh : highGlucose,
            lowGlucoseColorValue: isDynamicColorScheme ? hardCodedLow : lowGlucose,
            targetGlucose: currentGlucoseTarget,
            glucoseColorScheme: glucoseColorScheme
        )
        // Off-world (static scheme only): in-range points are neon cyan, high points amber, low stock.
        return OffworldTheme.glucoseColor(
            stock: stock,
            band: OffworldTheme.band(value: Decimal(item.glucose), low: lowGlucose, high: highGlucose),
            isStaticScheme: glucoseColorScheme == .staticColor,
            inRange: .cyan,
            replacesDynamicInRange: false
        )
    }

    private func drawGlucoseChart() -> some ChartContent {
        ForEach(glucoseData) { item in
            let glucoseToDisplay = units == .mgdL ? Decimal(item.glucose) : Decimal(item.glucose).asMmolL

            if item.isManual {
                PointMark(
                    x: .value("Time", item.date ?? Date(), unit: .second),
                    y: .value("Value", glucoseToDisplay)
                )
                .symbolSize(20)
                .symbol {
                    Image(systemName: "drop.fill")
                        .font(.caption2)
                        .symbolRenderingMode(.monochrome)
                        .bold()
                        .foregroundStyle(.red)
                }
            } else {
                PointMark(
                    x: .value("Time", item.date ?? Date(), unit: .second),
                    y: .value("Value", glucoseToDisplay)
                )
                .foregroundStyle(pointColor(for: item))
                .symbolSize(20)
                .symbol(.circle)
            }

            if isSmoothingEnabled, let smoothedGlucose = item.smoothedGlucose, smoothedGlucose != 0 {
                let smoothedGlucoseForDisplay: Decimal = units == .mgdL ? smoothedGlucose.decimalValue : smoothedGlucose
                    .decimalValue.asMmolL
                LineMark(
                    x: .value("Time", item.date ?? Date(), unit: .second),
                    y: .value("Value", smoothedGlucoseForDisplay),
                    series: .value("Type", "Smoothed")
                )
                .foregroundStyle(Color.secondary)
            }
        }
    }

    // MARK: - Off-world trace (theme on only)

    /// Line colour for a band: stock low colour, cyan in range, amber high (static scheme).
    private func bandColor(_ band: OffworldTheme.GlucoseBand) -> Color {
        let probe: Decimal
        switch band {
        case .low: probe = lowGlucose
        case .high: probe = highGlucose
        case .inRange: probe = (lowGlucose + highGlucose) / 2
        }
        return OffworldTheme.homeGlucoseColor(
            value: probe,
            low: lowGlucose,
            high: highGlucose,
            target: currentGlucoseTarget,
            scheme: glucoseColorScheme,
            inRange: .cyan
        )
    }

    private func displayValue(_ item: GlucoseStored) -> Decimal {
        units == .mgdL ? Decimal(item.glucose) : Decimal(item.glucose).asMmolL
    }

    /// A glowing line through consecutive CGM readings, broken wherever readings are more than
    /// `OffworldTrace.maxGap` apart so missing data is never bridged. Fingersticks keep the stock drop.
    @ChartContentBuilder private func drawOffworldGlucose() -> some ChartContent {
        let cgm = glucoseData.filter { !$0.isManual && $0.date != nil }.sorted { $0.date! < $1.date! }
        let trace = OffworldTrace.groups(cgm.enumerated().map { index, item in
            OffworldTrace.Sample(
                id: index,
                date: item.date!,
                band: OffworldTheme.band(value: Decimal(item.glucose), low: lowGlucose, high: highGlucose),
                value: NSDecimalNumber(decimal: displayValue(item)).doubleValue
            )
        })
        let lowLimit = NSDecimalNumber(decimal: units == .mgdL ? lowGlucose : lowGlucose.asMmolL).doubleValue
        let highLimit = NSDecimalNumber(decimal: units == .mgdL ? highGlucose : highGlucose.asMmolL).doubleValue

        ForEach(Array(trace.runs.enumerated()), id: \.offset) { runIndex, run in
            // One path per gap-free run. The gradient runs bottom to top over the run's own value
            // range with hard stops at the thresholds, so colour changes exactly where the line crosses.
            let values = run.map(\.value)
            let style = LinearGradient(
                stops: OffworldTrace.bandStops(
                    minValue: values.min() ?? 0,
                    maxValue: values.max() ?? 0,
                    low: lowLimit,
                    high: highLimit
                ).map { Gradient.Stop(color: bandColor($0.band), location: $0.location) },
                startPoint: .bottom,
                endPoint: .top
            )
            ForEach(run, id: \.id) { sample in
                LineMark(
                    x: .value("Time", sample.date, unit: .second),
                    y: .value("Value", displayValue(cgm[sample.id])),
                    series: .value("Run", "glow-\(runIndex)")
                )
                .foregroundStyle(style.opacity(0.16))
                .lineStyle(StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            ForEach(run, id: \.id) { sample in
                LineMark(
                    x: .value("Time", sample.date, unit: .second),
                    y: .value("Value", displayValue(cgm[sample.id])),
                    series: .value("Run", "line-\(runIndex)")
                )
                .foregroundStyle(style)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }

        // readings with no neighbour close enough to connect to stay as dots
        ForEach(trace.isolated, id: \.id) { sample in
            PointMark(
                x: .value("Time", sample.date, unit: .second),
                y: .value("Value", displayValue(cgm[sample.id]))
            )
            .foregroundStyle(pointColor(for: cgm[sample.id]))
            .symbolSize(20)
            .symbol(.circle)
        }

        ForEach(glucoseData.filter(\.isManual)) { item in
            PointMark(
                x: .value("Time", item.date ?? Date(), unit: .second),
                y: .value("Value", displayValue(item))
            )
            .symbolSize(20)
            .symbol {
                Image(systemName: "drop.fill")
                    .font(.caption2)
                    .symbolRenderingMode(.monochrome)
                    .bold()
                    .foregroundStyle(.red)
            }
        }

        if isSmoothingEnabled {
            ForEach(glucoseData.filter { ($0.smoothedGlucose ?? 0) != 0 }) { item in
                LineMark(
                    x: .value("Time", item.date ?? Date(), unit: .second),
                    y: .value(
                        "Value",
                        units == .mgdL ? item.smoothedGlucose!.decimalValue : item.smoothedGlucose!.decimalValue.asMmolL
                    ),
                    series: .value("Type", "Smoothed")
                )
                .foregroundStyle(Color.secondary)
            }
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State private var previewStack: CoreDataStack? = nil
        @State private var glucoseData: [GlucoseStored] = []
        @State private var isLoading = true

        var body: some View {
            NavigationView {
                Group {
                    if isLoading {
                        ProgressView("Loading data...")
                    } else {
                        VStack {
                            Chart {
                                GlucoseChartView(
                                    glucoseData: glucoseData,
                                    units: .mgdL,
                                    highGlucose: 180,
                                    lowGlucose: 70,
                                    currentGlucoseTarget: 100,
                                    isSmoothingEnabled: false,
                                    glucoseColorScheme: .dynamicColor
                                )
                            }
                            .frame(height: 200)
                            .padding()
                        }
                    }
                }
                .navigationTitle("Glucose Chart")
                .task {
                    // Use the preview stack that's initialized asynchronously in CoreDataStack
                    previewStack = try? await CoreDataStack.preview()

                    // Now you can safely create preview data
                    if let stack = previewStack {
                        glucoseData = GlucoseStored.makePreviewGlucose(count: 24, provider: stack)
                        isLoading = false
                    }
                }
            }
        }
    }

    return PreviewWrapper()
}
