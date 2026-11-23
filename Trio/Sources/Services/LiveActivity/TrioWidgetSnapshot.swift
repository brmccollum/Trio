import Foundation

// Shared by the app target and the widget extension (LiveActivityExtension). Foundation only.
// Display only: nothing here is read by the algorithm, the pump, the CGM or Nightscout code.

/// What the home-screen and lock-screen glucose widgets draw.
///
/// The app writes one of these to the shared app-group defaults each time a glucose reading arrives.
/// The widget never treats it as current on its own: every drawing decision goes through
/// `TrioWidgetFreshness`, which compares `readingDate` with the time the widget is drawn for.
struct TrioWidgetSnapshot: Codable, Equatable {
    struct Point: Codable, Equatable {
        let date: Date
        let mgdL: Int
    }

    static let currentVersion = 1

    /// Format version. A snapshot with another version is ignored (the widget shows its placeholder).
    var version: Int = TrioWidgetSnapshot.currentVersion
    /// Glucose as shown to the user, already in their unit ("112" or "6.2").
    let glucose: String
    /// The same reading in mg/dL, used only to pick the band.
    let glucoseMgdL: Int
    /// "mg/dL" or "mmol/L".
    let unit: String
    /// Trend arrow text ("→", "↗︎", ...), or nil when the source gave none.
    let direction: String?
    /// Change since the previous reading, signed, in the user's unit ("+2"). Empty when unknown.
    let delta: String
    /// When the CGM took the reading. This, never the time of writing, drives staleness.
    let readingDate: Date
    /// The user's low and high thresholds in mg/dL.
    let low: Double
    let high: Double
    /// True while the optional Off-world theme is on in the app.
    let offworld: Bool
    /// Display strings, nil when the app had no value.
    let iob: String?
    let cob: String?
    /// Oldest first, about the last three hours, for the sparkline.
    let recent: [Point]
}

// MARK: - Storage

enum TrioWidgetSnapshotStore {
    /// WidgetKit kind of the glucose widget; the app asks for reloads of this kind.
    static let widgetKind = "TrioGlucoseWidget"
    static let defaultsKey = "trio.widget.glucoseSnapshot"
    /// How much history the sparkline carries, and the most points kept for it.
    static let recentWindow: TimeInterval = 3 * 60 * 60
    static let recentMaxPoints = 48

    /// App group suite name from the bundle's Info.plist (`AppGroupID`), nil when it is missing
    /// or was never expanded by the build.
    static func suiteName(bundle: Bundle = .main) -> String? {
        guard let name = bundle.object(forInfoDictionaryKey: "AppGroupID") as? String,
              !name.isEmpty, !name.contains("$(")
        else { return nil }
        return name
    }

    static func sharedDefaults(bundle: Bundle = .main) -> UserDefaults? {
        suiteName(bundle: bundle).flatMap { UserDefaults(suiteName: $0) }
    }

    static func encode(_ snapshot: TrioWidgetSnapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    /// Nil for missing, unreadable or other-version data. Never throws.
    static func decode(_ data: Data?) -> TrioWidgetSnapshot? {
        guard let data, let snapshot = try? JSONDecoder().decode(TrioWidgetSnapshot.self, from: data),
              snapshot.version == TrioWidgetSnapshot.currentVersion
        else { return nil }
        return snapshot
    }

    @discardableResult static func write(_ snapshot: TrioWidgetSnapshot, to defaults: UserDefaults) -> Bool {
        guard let data = encode(snapshot) else { return false }
        defaults.set(data, forKey: defaultsKey)
        return true
    }

    static func read(from defaults: UserDefaults?) -> TrioWidgetSnapshot? {
        decode(defaults?.data(forKey: defaultsKey))
    }

    /// Readings for the sparkline: within `recentWindow` of the newest one, oldest first,
    /// thinned evenly (always keeping the newest) when there are more than `recentMaxPoints`.
    static func recentPoints(from readings: [TrioWidgetSnapshot.Point]) -> [TrioWidgetSnapshot.Point] {
        guard let newest = readings.map(\.date).max() else { return [] }
        let cutoff = newest.addingTimeInterval(-recentWindow)
        let window = readings.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
        guard window.count > recentMaxPoints else { return window }
        let step = Double(window.count - 1) / Double(recentMaxPoints - 1)
        return (0 ..< recentMaxPoints).map { window[Int((Double($0) * step).rounded())] }
    }
}

// MARK: - Staleness

/// How much a reading may be trusted at a given moment. This is the widget's safety rule:
/// an old number is never drawn as if it were current.
enum TrioWidgetFreshness: Equatable {
    /// Nothing has been published yet.
    case noSnapshot
    /// Younger than 15 minutes: drawn normally.
    case fresh
    /// 15 to 30 minutes old: the number is dimmed and its age is called out.
    case aging
    /// 30 minutes or older (or dated impossibly far in the future): dashes and "no data".
    case expired

    static let agingAfter: TimeInterval = 15 * 60
    static let expiredAfter: TimeInterval = 30 * 60
    /// A reading stamped slightly ahead of the clock is accepted as new; further ahead is not trusted.
    static let futureTolerance: TimeInterval = 5 * 60
    /// How long after its last planned entry the widget asks WidgetKit to read the store again.
    static let recheckInterval: TimeInterval = 15 * 60

    static func of(readingDate: Date?, at now: Date) -> TrioWidgetFreshness {
        guard let readingDate else { return .noSnapshot }
        let age = now.timeIntervalSince(readingDate)
        if age < -futureTolerance { return .expired }
        if age < agingAfter { return .fresh }
        if age < expiredAfter { return .aging }
        return .expired
    }

    /// Whole minutes since the reading, never negative.
    static func minutesAgo(readingDate: Date, at now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(readingDate) / 60))
    }

    /// Dates the widget timeline needs entries for: now, then every whole minute of the reading's age
    /// up to the 30-minute mark, so the minutes-ago text, the dimming at 15 minutes and the dashes at
    /// 30 minutes all happen on the widget's own schedule, with no further word from the app.
    static func timelineDates(readingDate: Date?, now: Date) -> [Date] {
        guard let readingDate, of(readingDate: readingDate, at: now) != .expired else { return [now] }
        let lastMinute = Int(expiredAfter / 60)
        let later = (1 ... lastMinute)
            .map { readingDate.addingTimeInterval(TimeInterval($0) * 60) }
            .filter { $0 > now }
        return [now] + later
    }

    /// When WidgetKit should ask for a new timeline if the app has not requested one sooner.
    static func reloadDate(afterLastEntry lastEntry: Date) -> Date {
        lastEntry.addingTimeInterval(recheckInterval)
    }
}

// MARK: - Band and colour roles

enum TrioWidgetBand: Equatable {
    case low
    case inRange
    case high

    /// Same comparisons as the stock static scheme: at or below low is low, at or above high is high.
    static func of(mgdL: Int, low: Double, high: Double) -> TrioWidgetBand {
        let value = Double(mgdL)
        if value <= low { return .low }
        if value >= high { return .high }
        return .inRange
    }
}

/// Which colour the number takes. The extension maps each case to a `Color`.
enum TrioWidgetTone: Equatable {
    /// Stock red. Low is red with or without the theme.
    case low
    /// Stock static-scheme green and purple (theme off).
    case stockInRange
    case stockHigh
    /// Off-world mint and amber (theme on).
    case themedInRange
    case themedHigh
    /// Dimmed, band-less: an aging reading, or no number at all.
    case dimmed

    /// Off-world values as 0xRRGGBB; must equal `OffworldTheme.Swatch.mint` and `.amber` (tested).
    static let themedInRangeHex: UInt32 = 0x7DFFB2
    static let themedHighHex: UInt32 = 0xFFB000

    static func of(band: TrioWidgetBand?, themed: Bool, freshness: TrioWidgetFreshness) -> TrioWidgetTone {
        guard freshness == .fresh, let band else { return .dimmed }
        switch band {
        case .low: return .low
        case .inRange: return themed ? .themedInRange : .stockInRange
        case .high: return themed ? .themedHigh : .stockHigh
        }
    }
}

// MARK: - What a widget shows

/// Everything a widget family needs, decided in one place from a snapshot and the moment it is drawn for.
struct TrioWidgetDisplay: Equatable {
    static let dashes = "--"

    let freshness: TrioWidgetFreshness
    /// The glucose string, or dashes when there is no snapshot or it has expired.
    let number: String
    let tone: TrioWidgetTone
    /// Band of the reading, only while it is fresh (an old low is not announced as a current low).
    let band: TrioWidgetBand?
    let themed: Bool
    /// Arrow, delta and unit, only while a number is shown.
    let direction: String?
    let delta: String?
    let unit: String?
    /// Whole minutes since the reading; nil when there is no snapshot.
    let minutesAgo: Int?
    let readingDate: Date?
    /// Only while fresh.
    let iob: String?
    let cob: String?
    /// Sparkline points, only while a number is shown.
    let recent: [TrioWidgetSnapshot.Point]
    let low: Double
    let high: Double

    var showsNumber: Bool { freshness == .fresh || freshness == .aging }
    var isLow: Bool { band == .low }

    init(snapshot: TrioWidgetSnapshot?, at now: Date) {
        let freshness = TrioWidgetFreshness.of(readingDate: snapshot?.readingDate, at: now)
        self.freshness = freshness
        let shows = freshness == .fresh || freshness == .aging
        let band: TrioWidgetBand? = (freshness == .fresh ? snapshot : nil)
            .map { TrioWidgetBand.of(mgdL: $0.glucoseMgdL, low: $0.low, high: $0.high) }
        self.band = band
        themed = snapshot?.offworld ?? false
        number = shows ? (snapshot?.glucose ?? Self.dashes) : Self.dashes
        tone = TrioWidgetTone.of(band: band, themed: themed, freshness: freshness)
        direction = shows ? snapshot?.direction : nil
        let trimmedDelta = snapshot?.delta.trimmingCharacters(in: .whitespaces) ?? ""
        delta = shows && !trimmedDelta.isEmpty ? trimmedDelta : nil
        unit = shows ? snapshot?.unit : nil
        readingDate = snapshot?.readingDate
        minutesAgo = snapshot.map { TrioWidgetFreshness.minutesAgo(readingDate: $0.readingDate, at: now) }
        iob = freshness == .fresh ? snapshot?.iob : nil
        cob = freshness == .fresh ? snapshot?.cob : nil
        recent = shows ? (snapshot?.recent ?? []) : []
        low = snapshot?.low ?? 0
        high = snapshot?.high ?? 0
    }
}
