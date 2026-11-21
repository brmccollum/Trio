import Foundation
import SwiftUI
import Testing

@testable import Trio

/// Tests for the optional Off-world appearance: flag storage, palette lookup and contrast.
/// Pure: every test uses its own throwaway UserDefaults suite, never the app's standard one.
@Suite("Off-world theme tests") struct OffworldThemeTests {
    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "offworld-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("Theme is off by default and uses its own key") func defaultsToOff() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        #expect(OffworldTheme.defaultsKey == "bryan.theme.offworld")
        #expect(OffworldTheme.isEnabled(in: defaults) == false)
    }

    @Test("Flag round-trips through UserDefaults") func flagRoundTrips() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        OffworldTheme.setEnabled(true, in: defaults)
        #expect(defaults.bool(forKey: "bryan.theme.offworld") == true)
        #expect(OffworldTheme.isEnabled(in: defaults) == true)

        OffworldTheme.setEnabled(false, in: defaults)
        #expect(OffworldTheme.isEnabled(in: defaults) == false)
    }

    @Test("Lookup returns the stock colour when off and the swatch when on") func lookup() {
        let stock = Color.red
        #expect(OffworldTheme.resolve(stock, themed: .panel, enabled: false) == stock)
        #expect(OffworldTheme.resolve(stock, themed: .panel, enabled: true) == OffworldTheme.Swatch.panel.color)
    }

    @Test("Theme forces dark only while on") func colorScheme() {
        #expect(OffworldTheme.colorScheme(stock: .light, enabled: true) == .dark)
        #expect(OffworldTheme.colorScheme(stock: nil, enabled: true) == .dark)
        #expect(OffworldTheme.colorScheme(stock: .light, enabled: false) == .light)
        #expect(OffworldTheme.colorScheme(stock: nil, enabled: false) == nil)
    }

    @Test("Swatch components decode the hex value") func components() {
        let cyan = OffworldTheme.Swatch.cyan.components
        #expect(abs(cyan.red - 46.0 / 255) < 0.0001)
        #expect(abs(cyan.green - 242.0 / 255) < 0.0001)
        #expect(abs(cyan.blue - 1.0) < 0.0001)
    }

    @Test("Text and accent swatches meet WCAG AA on every themed surface") func contrast() {
        let surfaces: [OffworldTheme.Swatch] = [.background, .backgroundLift, .panel, .panelRaised, .panelTeal]
        let foregrounds: [OffworldTheme.Swatch] = [.ink, .muted, .cyan, .amber, .pink, .mint, .gold, .silver]
        for surface in surfaces {
            for foreground in foregrounds {
                #expect(
                    OffworldTheme.contrastRatio(foreground, surface) >= 4.5,
                    "\(foreground) on \(surface)"
                )
            }
        }
    }

    @Test("Themed surfaces are no lighter than the stock dark card") func surfacesStayDark() {
        // Stock dark "Chart" is sRGB (0.13, 0.13, 0.18), luminance about 0.016. White and the stock
        // status colours sit on it today; a darker surface can only raise their contrast.
        for surface in [OffworldTheme.Swatch.background, .backgroundLift, .panel, .panelRaised, .panelTeal] {
            #expect(surface.relativeLuminance <= 0.016, "\(surface)")
        }
    }
}

/// The watch only learns about the theme through the display state the phone already sends.
@Suite("Off-world watch state tests") struct OffworldWatchStateTests {
    @Test("The flag defaults to off and takes part in equality") func flagInState() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var plain = WatchState(date: date)
        let themed: WatchState = {
            var state = WatchState(date: date)
            state.offworldTheme = true
            return state
        }()
        #expect(plain.offworldTheme == false)
        #expect(plain != themed)
        plain.offworldTheme = true
        #expect(plain == themed)
        #expect(plain.hashValue == themed.hashValue)
    }

    @Test("The message key is its own, display-only key") func messageKey() {
        #expect(WatchMessageKeys.offworldTheme == "offworldTheme")
    }
}

/// The Home rain is decoration; these pin down when it is allowed to run at all.
@Suite("Off-world rain policy tests") struct OffworldRainPolicyTests {
    private func active(
        theme: Bool = true,
        reduceMotion: Bool = false,
        lowPower: Bool = false,
        sceneActive: Bool = true,
        modal: Bool = false,
        homeVisible: Bool = true
    ) -> Bool {
        OffworldRainPolicy.isActive(
            themeOn: theme,
            reduceMotion: reduceMotion,
            lowPowerMode: lowPower,
            sceneActive: sceneActive,
            modalPresented: modal,
            homeVisible: homeVisible
        )
    }

    @Test("Runs only with the theme on and nothing asking it to stop") func policy() {
        #expect(active())
        #expect(!active(theme: false))
        #expect(!active(reduceMotion: true))
        #expect(!active(lowPower: true))
        #expect(!active(sceneActive: false))
        #expect(!active(modal: true))
        #expect(!active(homeVisible: false))
    }

    @Test("Frame rate and drop count stay small") func budget() {
        #expect(OffworldRainPolicy.framesPerSecond <= 30)
        #expect(OffworldRainPolicy.dropCount <= 80)
    }

    @Test("Drop positions are deterministic and stay near the screen") func positions() {
        for index in 0 ..< OffworldRainPolicy.dropCount {
            for time in stride(from: 0.0, through: 30.0, by: 0.7) {
                let a = OffworldRainPolicy.dropPosition(index: index, time: time)
                let b = OffworldRainPolicy.dropPosition(index: index, time: time)
                #expect(a == b)
                #expect(a.x > -0.5 && a.x < 1.3)
                #expect(a.y >= -0.11 && a.y <= 1.06)
            }
        }
    }
}

@Suite("Off-world edge sweep tests") struct OffworldEdgeSweepTests {
    @Test("The light crosses once per period and rests in between") func progress() {
        #expect(OffworldEdgeSweep.progress(at: 0) == 0)
        let mid = OffworldEdgeSweep.progress(at: OffworldEdgeSweep.travel / 2)
        #expect(mid != nil && abs(mid! - 0.5) < 0.0001)
        #expect(OffworldEdgeSweep.progress(at: OffworldEdgeSweep.travel + 0.1) == nil)
        #expect(OffworldEdgeSweep.progress(at: OffworldEdgeSweep.period - 0.1) == nil)
        #expect(OffworldEdgeSweep.progress(at: OffworldEdgeSweep.period) == 0)
        #expect(OffworldEdgeSweep.travel < OffworldEdgeSweep.period)
    }
}

@Suite("Off-world glucose colour tests") struct OffworldGlucoseColorTests {
    private let stock = Color.red

    private func color(
        _ band: OffworldTheme.GlucoseBand,
        isStatic: Bool = true,
        replacesDynamic: Bool = false,
        enabled: Bool = true
    ) -> Color {
        OffworldTheme.glucoseColor(
            stock: stock,
            band: band,
            isStaticScheme: isStatic,
            inRange: .cyan,
            replacesDynamicInRange: replacesDynamic,
            enabled: enabled
        )
    }

    @Test("Bands use the stock comparisons") func bands() {
        #expect(OffworldTheme.band(value: 70, low: 70, high: 180) == .low)
        #expect(OffworldTheme.band(value: 71, low: 70, high: 180) == .inRange)
        #expect(OffworldTheme.band(value: 179, low: 70, high: 180) == .inRange)
        #expect(OffworldTheme.band(value: 180, low: 70, high: 180) == .high)
    }

    @Test("Low always keeps the stock colour") func lowIsStock() {
        #expect(color(.low) == stock)
        #expect(color(.low, isStatic: false, replacesDynamic: true) == stock)
    }

    @Test("Theme off returns stock for every band") func offIsStock() {
        for band in [OffworldTheme.GlucoseBand.low, .inRange, .high] {
            #expect(color(band, enabled: false) == stock)
        }
    }

    @Test("Static scheme: cyan in range, amber high") func staticScheme() {
        #expect(color(.inRange) == OffworldTheme.Swatch.cyan.color)
        #expect(color(.high) == OffworldTheme.Swatch.amber.color)
    }

    @Test("Dynamic scheme keeps the user's gradient") func dynamicScheme() {
        #expect(color(.high, isStatic: false) == stock)
        #expect(color(.inRange, isStatic: false) == stock)
        #expect(color(.inRange, isStatic: false, replacesDynamic: true) == OffworldTheme.Swatch.cyan.color)
    }

    @Test("Amber (high) and cyan (in range) stay far apart in luminance from each other's neighbours") func distinct() {
        // Red low (stock, about #EB5757) has luminance near 0.26; amber is near 0.52, cyan near 0.72.
        #expect(OffworldTheme.Swatch.amber.relativeLuminance > 0.45)
        #expect(OffworldTheme.Swatch.cyan.relativeLuminance - OffworldTheme.Swatch.amber.relativeLuminance > 0.15)
    }

    @Test("Bezel sheen angle wraps once per period") func sheen() {
        #expect(OffworldBezelDecor.sheenAngle(at: 0) == 0)
        #expect(abs(OffworldBezelDecor.sheenAngle(at: OffworldBezelDecor.sheenPeriod / 2) - 180) < 0.0001)
        #expect(OffworldBezelDecor.sheenAngle(at: OffworldBezelDecor.sheenPeriod) == 0)
    }
}

@Suite("Off-world trace tests") struct OffworldTraceTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func samples(_ spec: [(minutes: Double, band: OffworldTheme.GlucoseBand)]) -> [OffworldTrace.Sample] {
        spec.enumerated().map { index, item in
            OffworldTrace.Sample(id: index, date: start.addingTimeInterval(item.minutes * 60), band: item.band)
        }
    }

    @Test("Readings five minutes apart form one run") func oneRun() {
        let trace = OffworldTrace.build(samples([(0, .inRange), (5, .inRange), (10, .inRange)]))
        #expect(trace.runs.count == 1)
        #expect(trace.runs[0].samples.map(\.id) == [0, 1, 2])
        #expect(trace.isolated.isEmpty)
    }

    @Test("A gap longer than eleven minutes is never bridged") func gapBreaksLine() {
        let trace = OffworldTrace.build(samples([(0, .inRange), (5, .inRange), (20, .inRange), (25, .inRange)]))
        #expect(trace.runs.map { $0.samples.map(\.id) } == [[0, 1], [2, 3]])
        for run in trace.runs {
            for (a, b) in zip(run.samples, run.samples.dropFirst()) {
                #expect(b.date.timeIntervalSince(a.date) <= OffworldTrace.maxGap)
            }
        }
    }

    @Test("Ten minutes apart still connects, twelve does not") func boundary() {
        #expect(OffworldTrace.build(samples([(0, .inRange), (10, .inRange)])).runs.count == 1)
        let apart = OffworldTrace.build(samples([(0, .inRange), (12, .inRange)]))
        #expect(apart.runs.isEmpty)
        #expect(apart.isolated.map(\.id) == [0, 1])
    }

    @Test("A reading with no close neighbour stays a dot") func isolated() {
        let trace = OffworldTrace.build(samples([(0, .inRange), (5, .inRange), (40, .low), (90, .high), (95, .high)]))
        #expect(trace.isolated.map(\.id) == [2])
        #expect(trace.runs.count == 2)
    }

    @Test("A band change starts a new run at the shared reading") func bandChange() {
        let trace = OffworldTrace.build(samples([(0, .inRange), (5, .inRange), (10, .low), (15, .low), (20, .inRange)]))
        #expect(trace.runs.map(\.band) == [.inRange, .low, .inRange])
        #expect(trace.runs.map { $0.samples.map(\.id) } == [[0, 1], [1, 2, 3], [3, 4]])
    }

    @Test("Empty and single inputs") func degenerate() {
        #expect(OffworldTrace.build([]).runs.isEmpty)
        let one = OffworldTrace.build(samples([(0, .high)]))
        #expect(one.runs.isEmpty && one.isolated.count == 1)
    }

    @Test("Pulse and scan timing are bounded") func timing() {
        #expect(OffworldNewestReading.phase(at: 0) == 0)
        #expect(OffworldNewestReading.phase(at: OffworldNewestReading.period * 0.5) == 0.5)
        #expect(OffworldScanBar.progress(at: 0) == 0)
        #expect(OffworldScanBar.progress(at: OffworldScanBar.travel + 0.1) == nil)
    }
}

@Suite("Off-world line colour tests") struct OffworldTraceColourTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Groups never join readings across a gap") func groups() {
        let samples = [0.0, 5, 10, 30, 35, 80].enumerated().map { index, minutes in
            OffworldTrace.Sample(id: index, date: start.addingTimeInterval(minutes * 60), band: .inRange, value: 100)
        }
        let result = OffworldTrace.groups(samples)
        #expect(result.runs.map { $0.map(\.id) } == [[0, 1, 2], [3, 4]])
        #expect(result.isolated.map(\.id) == [5])
    }

    @Test("A run entirely in range is one colour") func inRangeOnly() {
        let stops = OffworldTrace.bandStops(minValue: 90, maxValue: 150, low: 70, high: 180)
        #expect(Set(stops.map(\.band)) == [.inRange])
        #expect(stops.first?.location == 0 && stops.last?.location == 1)
    }

    @Test("Colour changes exactly at the thresholds") func crossings() {
        let stops = OffworldTrace.bandStops(minValue: 60, maxValue: 200, low: 70, high: 180)
        #expect(stops.map(\.band) == [.low, .low, .inRange, .inRange, .high, .high])
        let lowEdge = (70.0 - 60) / 140
        let highEdge = (180.0 - 60) / 140
        #expect(abs(stops[1].location - lowEdge) < 1E-9 && abs(stops[2].location - lowEdge) < 1E-9)
        #expect(abs(stops[3].location - highEdge) < 1E-9 && abs(stops[4].location - highEdge) < 1E-9)
    }

    @Test("Only the bands a run touches appear") func partial() {
        #expect(
            OffworldTrace.bandStops(minValue: 100, maxValue: 220, low: 70, high: 180).map(\.band)
                == [.inRange, .inRange, .high, .high]
        )
        #expect(OffworldTrace.bandStops(minValue: 50, maxValue: 65, low: 70, high: 180).map(\.band) == [.low, .low])
        #expect(OffworldTrace.bandStops(minValue: 190, maxValue: 190, low: 70, high: 180).map(\.band) == [.high, .high])
    }

    @Test("Axis font is stock when the theme is off") func axisFont() {
        #expect(OffworldTheme.axisLabelFont(stock: .footnote, enabled: false) == .footnote)
        #expect(OffworldTheme.axisLabelFont(stock: .footnote, enabled: true) != .footnote)
    }
}

@Suite("Off-world font tests") struct OffworldFontTests {
    @Test("The bundled Orbitron file is in the app and registers") func bundled() {
        #expect(Bundle.main.url(forResource: OffworldFont.fileName, withExtension: "ttf") != nil)
        #expect(OffworldFont.isAvailable)
        #expect(UIFont.fontNames(forFamilyName: OffworldFont.familyName).isEmpty == false)
    }
}

@Suite("Off-world chart element tests") struct OffworldChartElementTests {
    @Test("The forecast wave never leaves the real forecast bounds") func waveStaysInsideEnvelope() {
        let low: [Double] = [133, 128, 120, 111, 104, 99, 96, 95, 95, 96]
        let high: [Double] = [133, 137, 144, 150, 155, 158, 158, 157, 155, 152]
        let samples = OffworldForecastWave.samples(low: low, high: high)

        #expect(samples.count == (low.count - 1) * OffworldForecastWave.samplesPerStep + 1)
        #expect(samples.first?.value == 133)
        #expect(samples.last?.offset == Double(low.count - 1) * 300)
        for sample in samples {
            let position = sample.offset / 300
            let index = min(Int(position), low.count - 2)
            let fraction = position - Double(index)
            let lower = low[index] + (low[index + 1] - low[index]) * fraction
            let upper = high[index] + (high[index + 1] - high[index]) * fraction
            #expect(sample.value >= lower - 1E-9 && sample.value <= upper + 1E-9)
        }
        #expect(OffworldForecastWave.samples(low: [100], high: [120]).isEmpty)
    }

    @Test("A manual bolus is always drawn larger than an SMB") func manualBolusLargerThanSMB() {
        for stockSize in stride(from: CGFloat(5), through: 40, by: 2.5) {
            #expect(
                OffworldChartGlyph.width(kind: .manualBolus, stockSize: stockSize) >
                    OffworldChartGlyph.width(kind: .smb, stockSize: stockSize) + 3
            )
        }
        // the smallest manual bolus still outsizes a typical SMB
        #expect(OffworldChartGlyph.width(kind: .manualBolus, stockSize: 5) > OffworldChartGlyph.width(kind: .smb, stockSize: 7))
    }

    @Test("Forecast curves get four different colours") func forecastLineColours() {
        let colours = ["iob", "cob", "uam", "zt"].map { OffworldTheme.forecastLineColor(type: $0) }
        #expect(Set(colours.map { "\($0)" }).count == 4)
    }
}
