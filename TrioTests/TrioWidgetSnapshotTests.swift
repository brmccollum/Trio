import Foundation
import Testing

@testable import Trio

/// Tests for the display-only snapshot behind the home-screen and lock-screen glucose widgets:
/// encoding, the staleness rules, band and colour roles, and the publisher's throttle.
/// Pure: made-up numbers, throwaway UserDefaults suites. Nothing here touches Core Data, the pump or the network.
@Suite("Trio widget snapshot tests") struct TrioWidgetSnapshotTests {
    private let reading = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        glucose: Int = 112,
        readingDate: Date? = nil,
        offworld: Bool = false,
        iob: String? = "1.2 U",
        cob: String? = "8 g"
    ) -> TrioWidgetSnapshot {
        let date = readingDate ?? reading
        return TrioWidgetSnapshot(
            glucose: "\(glucose)",
            glucoseMgdL: glucose,
            unit: "mg/dL",
            direction: "→",
            delta: "+2",
            readingDate: date,
            low: 70,
            high: 180,
            offworld: offworld,
            iob: iob,
            cob: cob,
            recent: (0 ..< 6).map {
                TrioWidgetSnapshot.Point(date: date.addingTimeInterval(Double($0 - 5) * 300), mgdL: glucose - 5 + $0)
            }
        )
    }

    private func display(_ snapshot: TrioWidgetSnapshot?, minutes: Double) -> TrioWidgetDisplay {
        TrioWidgetDisplay(snapshot: snapshot, at: reading.addingTimeInterval(minutes * 60))
    }

    private func temporaryDefaults() -> UserDefaults {
        UserDefaults(suiteName: "TrioWidgetSnapshotTests-\(UUID().uuidString)")!
    }

    // MARK: - Encode and decode

    @Test("Round-trips through encode and decode") func roundTrip() throws {
        let original = snapshot(offworld: true)
        let decoded = TrioWidgetSnapshotStore.decode(TrioWidgetSnapshotStore.encode(original))
        #expect(decoded == original)
        #expect(decoded?.readingDate == reading)
        #expect(decoded?.recent.count == 6)
    }

    @Test("Nil strings survive the round trip") func roundTripWithoutOptionalValues() {
        let original = snapshot(iob: nil, cob: nil)
        #expect(TrioWidgetSnapshotStore.decode(TrioWidgetSnapshotStore.encode(original)) == original)
    }

    @Test("Missing, broken or other-version data decodes to nil") func decodeRejects() throws {
        #expect(TrioWidgetSnapshotStore.decode(nil) == nil)
        #expect(TrioWidgetSnapshotStore.decode(Data("not json".utf8)) == nil)
        #expect(TrioWidgetSnapshotStore.decode(Data("{}".utf8)) == nil)

        var future = snapshot()
        future.version = TrioWidgetSnapshot.currentVersion + 1
        #expect(TrioWidgetSnapshotStore.decode(TrioWidgetSnapshotStore.encode(future)) == nil)
    }

    @Test("Store writes and reads a defaults suite") func storeReadWrite() {
        let defaults = temporaryDefaults()
        #expect(TrioWidgetSnapshotStore.read(from: defaults) == nil)
        #expect(TrioWidgetSnapshotStore.read(from: nil) == nil)
        #expect(TrioWidgetSnapshotStore.write(snapshot(), to: defaults))
        #expect(TrioWidgetSnapshotStore.read(from: defaults) == snapshot())
    }

    @Test("Sparkline points: three hours, oldest first, capped, newest kept") func recentPoints() {
        // One reading a minute for six hours, handed over newest first as the app fetches them.
        let all = (0 ..< 360)
            .map { TrioWidgetSnapshot.Point(date: reading.addingTimeInterval(Double(-$0) * 60), mgdL: 100 + $0 % 7) }
        let points = TrioWidgetSnapshotStore.recentPoints(from: all)
        #expect(points.count == TrioWidgetSnapshotStore.recentMaxPoints)
        #expect(points.last?.date == reading)
        #expect(points.first!.date >= reading.addingTimeInterval(-TrioWidgetSnapshotStore.recentWindow))
        #expect(points.map(\.date) == points.map(\.date).sorted())
        #expect(TrioWidgetSnapshotStore.recentPoints(from: []).isEmpty)
        #expect(TrioWidgetSnapshotStore.recentPoints(from: Array(all.prefix(10))).count == 10)
    }

    // MARK: - Staleness

    @Test("Fresh under 15 minutes, aging to 30, expired after") func freshnessBoundaries() {
        func at(_ seconds: TimeInterval) -> TrioWidgetFreshness {
            TrioWidgetFreshness.of(readingDate: reading, at: reading.addingTimeInterval(seconds))
        }
        #expect(at(0) == .fresh)
        #expect(at(14 * 60 + 59) == .fresh)
        #expect(at(15 * 60) == .aging)
        #expect(at(29 * 60 + 59) == .aging)
        #expect(at(30 * 60) == .expired)
        #expect(at(24 * 60 * 60) == .expired)
        #expect(TrioWidgetFreshness.of(readingDate: nil, at: reading) == .noSnapshot)
    }

    @Test("A reading stamped far in the future is not trusted") func futureReadings() {
        #expect(TrioWidgetFreshness.of(readingDate: reading.addingTimeInterval(60), at: reading) == .fresh)
        #expect(TrioWidgetFreshness.of(readingDate: reading.addingTimeInterval(6 * 60), at: reading) == .expired)
        #expect(TrioWidgetFreshness.minutesAgo(readingDate: reading.addingTimeInterval(60), at: reading) == 0)
    }

    @Test("Timeline carries the dimming and the dashes without the app") func timelineDates() {
        let now = reading.addingTimeInterval(2 * 60 + 20)
        let dates = TrioWidgetFreshness.timelineDates(readingDate: reading, now: now)

        #expect(dates.first == now)
        #expect(dates == dates.sorted())
        #expect(dates.count == 1 + 28) // now, then minutes 3 through 30 of the reading's age
        #expect(dates.contains(reading.addingTimeInterval(15 * 60)))
        #expect(dates.last == reading.addingTimeInterval(30 * 60))

        // What each planned entry will draw, with no new snapshot arriving.
        let states = dates.map { TrioWidgetDisplay(snapshot: snapshot(), at: $0).freshness }
        #expect(states.first == .fresh)
        #expect(states[dates.firstIndex(of: reading.addingTimeInterval(15 * 60))!] == .aging)
        #expect(states.last == .expired)
        #expect(!states.dropLast().contains(.expired))

        #expect(TrioWidgetFreshness.reloadDate(afterLastEntry: dates.last!) == reading.addingTimeInterval(45 * 60))
    }

    @Test("Timeline for no snapshot or an expired one is a single entry") func timelineWithoutUsableReading() {
        let now = reading.addingTimeInterval(45 * 60)
        #expect(TrioWidgetFreshness.timelineDates(readingDate: nil, now: now) == [now])
        #expect(TrioWidgetFreshness.timelineDates(readingDate: reading, now: now) == [now])
    }

    // MARK: - What is shown

    @Test("Fresh shows everything") func displayFresh() {
        let shown = display(snapshot(), minutes: 3.5)
        #expect(shown.freshness == .fresh)
        #expect(shown.number == "112")
        #expect(shown.direction == "→")
        #expect(shown.delta == "+2")
        #expect(shown.unit == "mg/dL")
        #expect(shown.minutesAgo == 3)
        #expect(shown.iob == "1.2 U")
        #expect(shown.cob == "8 g")
        #expect(shown.recent.count == 6)
        #expect(shown.band == .inRange)
    }

    @Test("Aging keeps the number but dims it and drops band, IOB and COB") func displayAging() {
        let shown = display(snapshot(glucose: 62, offworld: true), minutes: 18)
        #expect(shown.freshness == .aging)
        #expect(shown.number == "62")
        #expect(shown.minutesAgo == 18)
        #expect(shown.tone == .dimmed)
        #expect(shown.band == nil)
        #expect(shown.isLow == false) // an old low is not announced as a current low
        #expect(shown.iob == nil)
        #expect(shown.cob == nil)
    }

    @Test("Expired shows dashes, never the old number") func displayExpired() {
        let shown = display(snapshot(), minutes: 30)
        #expect(shown.freshness == .expired)
        #expect(shown.number == TrioWidgetDisplay.dashes)
        #expect(shown.showsNumber == false)
        #expect(shown.direction == nil)
        #expect(shown.delta == nil)
        #expect(shown.unit == nil)
        #expect(shown.recent.isEmpty)
        #expect(shown.iob == nil)
        #expect(shown.tone == .dimmed)
        #expect(shown.readingDate == reading) // still says when the last reading was
        #expect(shown.minutesAgo == 30)
    }

    @Test("No snapshot is a placeholder") func displayNoSnapshot() {
        let shown = display(nil, minutes: 0)
        #expect(shown.freshness == .noSnapshot)
        #expect(shown.number == TrioWidgetDisplay.dashes)
        #expect(shown.readingDate == nil)
        #expect(shown.minutesAgo == nil)
        #expect(shown.themed == false)
    }

    // MARK: - Band and colour

    @Test("Band edges match the stock static scheme") func bandEdges() {
        #expect(TrioWidgetBand.of(mgdL: 70, low: 70, high: 180) == .low)
        #expect(TrioWidgetBand.of(mgdL: 71, low: 70, high: 180) == .inRange)
        #expect(TrioWidgetBand.of(mgdL: 179, low: 70, high: 180) == .inRange)
        #expect(TrioWidgetBand.of(mgdL: 180, low: 70, high: 180) == .high)
        #expect(TrioWidgetBand.of(mgdL: 40, low: 70, high: 180) == .low)
    }

    @Test("Tone per band, theme off and on; low is the same red either way") func tones() {
        func tone(_ band: TrioWidgetBand?, themed: Bool, _ freshness: TrioWidgetFreshness = .fresh) -> TrioWidgetTone {
            TrioWidgetTone.of(band: band, themed: themed, freshness: freshness)
        }
        #expect(tone(.low, themed: false) == .low)
        #expect(tone(.low, themed: true) == .low)
        #expect(tone(.inRange, themed: false) == .stockInRange)
        #expect(tone(.inRange, themed: true) == .themedInRange)
        #expect(tone(.high, themed: false) == .stockHigh)
        #expect(tone(.high, themed: true) == .themedHigh)
        for freshness in [TrioWidgetFreshness.aging, .expired, .noSnapshot] {
            #expect(tone(.low, themed: true, freshness) == .dimmed)
            #expect(tone(.inRange, themed: false, freshness) == .dimmed)
        }
        #expect(tone(nil, themed: true) == .dimmed)
    }

    @Test("Themed colours are the app's Off-world mint and amber") func themedHexMatchesApp() {
        #expect(TrioWidgetTone.themedInRangeHex == OffworldTheme.Swatch.mint.rawValue)
        #expect(TrioWidgetTone.themedHighHex == OffworldTheme.Swatch.amber.rawValue)
    }

    @Test("Display picks the tone from the reading") func displayTones() {
        #expect(display(snapshot(glucose: 112, offworld: true), minutes: 1).tone == .themedInRange)
        #expect(display(snapshot(glucose: 205, offworld: true), minutes: 1).tone == .themedHigh)
        #expect(display(snapshot(glucose: 62, offworld: true), minutes: 1).tone == .low)
        #expect(display(snapshot(glucose: 62, offworld: true), minutes: 1).isLow)
        #expect(display(snapshot(glucose: 112), minutes: 1).tone == .stockInRange)
        #expect(display(snapshot(glucose: 205), minutes: 1).tone == .stockHigh)
        #expect(display(snapshot(glucose: 62), minutes: 1).tone == .low)
    }

    // MARK: - Publisher

    @Test("Publisher writes, and asks for one reload per reading") func publisherThrottle() {
        let defaults = temporaryDefaults()
        var reloads = [String]()
        let publisher = TrioWidgetSnapshotPublisher(defaults: { defaults }, reload: { reloads.append($0) })

        #expect(publisher.publish(snapshot()) == .written(reloaded: true))
        #expect(reloads == [TrioWidgetSnapshotStore.widgetKind])
        #expect(TrioWidgetSnapshotStore.read(from: defaults) == snapshot())

        // The same content again: nothing happens.
        #expect(publisher.publish(snapshot()) == .unchanged)

        // IOB and COB moved, same reading: stored, but no reload.
        #expect(publisher.publish(snapshot(iob: "1.4 U", cob: "6 g")) == .written(reloaded: false))
        #expect(TrioWidgetSnapshotStore.read(from: defaults)?.iob == "1.4 U")
        #expect(reloads.count == 1)

        // A new reading: reload.
        let next = snapshot(glucose: 115, readingDate: reading.addingTimeInterval(300))
        #expect(publisher.publish(next) == .written(reloaded: true))
        #expect(reloads.count == 2)

        // The theme flag changing redraws too.
        let themed = snapshot(glucose: 115, readingDate: reading.addingTimeInterval(300), offworld: true)
        #expect(publisher.publish(themed) == .written(reloaded: true))
        #expect(reloads.count == 3)
    }

    @Test("Publisher does nothing without shared defaults") func publisherUnavailable() {
        var reloads = 0
        let publisher = TrioWidgetSnapshotPublisher(defaults: { nil }, reload: { _ in reloads += 1 })
        #expect(publisher.publish(snapshot()) == .unavailable)
        #expect(reloads == 0)
    }

    @Test("Suite name is ignored when the build left the placeholder in") func suiteNameGuards() {
        // The test bundle has no AppGroupID key at all.
        #expect(TrioWidgetSnapshotStore.suiteName(bundle: Bundle(for: BundleMarker.self)) == nil)
    }

    // MARK: - Built from the app's readings

    @Test("Snapshot is built from the newest reading") func makeFromReadings() throws {
        // Newest first, five minutes apart, made-up values.
        let readings = [112, 110, 109, 111].enumerated().map { index, value in
            GlucoseData(glucose: value, date: reading.addingTimeInterval(Double(-index) * 300), direction: .flat)
        }
        let made = try #require(TrioWidgetSnapshot.make(
            readings: readings,
            units: .mgdL,
            low: 70,
            high: 180,
            iob: 1.25,
            cob: 8,
            offworld: true
        ))
        #expect(made.glucose == "112")
        #expect(made.glucoseMgdL == 112)
        #expect(made.unit == "mg/dL")
        #expect(made.direction == "→")
        #expect(made.delta == "+2")
        #expect(made.readingDate == reading)
        #expect(made.low == 70)
        #expect(made.high == 180)
        #expect(made.offworld)
        #expect(made.cob == "8 g")
        #expect(made.iob?.hasSuffix(" U") == true)
        #expect(made.recent.map(\.mgdL) == [111, 109, 110, 112])

        #expect(TrioWidgetSnapshot.make(
            readings: [],
            units: .mgdL,
            low: 70,
            high: 180,
            iob: nil,
            cob: nil,
            offworld: false
        ) == nil)
    }

    @Test("Snapshot in mmol/L keeps mg/dL for the band") func makeMmol() throws {
        let readings = [62, 66, 70].enumerated().map { index, value in
            GlucoseData(glucose: value, date: reading.addingTimeInterval(Double(-index) * 300), direction: .fortyFiveDown)
        }
        let made = try #require(TrioWidgetSnapshot.make(
            readings: readings,
            units: .mmolL,
            low: 70,
            high: 180,
            iob: nil,
            cob: nil,
            offworld: false
        ))
        #expect(made.unit == "mmol/L")
        #expect(made.glucoseMgdL == 62)
        #expect(made.iob == nil)
        #expect(made.cob == nil)
        #expect(TrioWidgetDisplay(snapshot: made, at: reading).band == .low)
    }
}

private final class BundleMarker {}
