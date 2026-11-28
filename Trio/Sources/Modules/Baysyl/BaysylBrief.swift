import Foundation

// The Baysyl brief: a small text file (`brief.json`) written by the Mac into a folder in iCloud Drive and read
// by the phone for display.
//
// Display only. Nothing in a brief is read by the algorithm, the pump, the CGM or any dosing code, and nothing
// in it is ever turned into an entry or a setting. This file is pure: no I/O, no clock.

/// One brief, after defensive decoding. Every string is already capped and flattened.
struct BaysylBrief: Codable, Equatable {
    struct Item: Codable, Equatable {
        var title: String
        /// 0 to 100, or nil when the file gave none (or gave something that is not a percent).
        var percent: Int?
        var detail: String
    }

    struct Test: Codable, Equatable {
        var title: String
        var predict: String
    }

    var updated: Date?
    var headline: String
    var items: [Item]
    var test: Test?
    var today: String?
}

enum BaysylBriefDecodeError: Error, Equatable {
    case tooLarge
    case notJSON
    case wrongShape
    case unsupportedVersion
    case noHeadline

    var message: String {
        switch self {
        case .tooLarge: return "brief.json is too large"
        case .notJSON: return "brief.json is not valid JSON"
        case .wrongShape: return "brief.json is not a brief"
        case .unsupportedVersion: return "brief.json is a version this build does not read"
        case .noHeadline: return "brief.json has no headline"
        }
    }
}

enum BaysylBriefDecoder {
    static let fileName = "brief.json"
    static let supportedVersion = 1
    /// A brief is a few hundred bytes. Anything beyond this is not read at all.
    static let maxBytes = 64 * 1024
    static let maxStringLength = 300
    static let maxItems = 6

    /// Reads schema version 1. Unknown fields are ignored; a field of the wrong type is treated as absent;
    /// strings are capped at `maxStringLength`; at most `maxItems` items are kept. Never throws or traps.
    static func decode(_ data: Data) -> Result<BaysylBrief, BaysylBriefDecodeError> {
        guard data.count <= maxBytes else { return .failure(.tooLarge) }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return .failure(.notJSON)
        }
        guard let root = object as? [String: Any] else { return .failure(.wrongShape) }
        guard let version = integer(root["v"]), version == supportedVersion else {
            return .failure(.unsupportedVersion)
        }
        guard let headline = string(root["headline"]) else { return .failure(.noHeadline) }

        var items: [BaysylBrief.Item] = []
        for case let raw as [String: Any] in (root["items"] as? [Any]) ?? [] {
            guard items.count < maxItems else { break }
            guard let title = string(raw["title"]) else { continue }
            items.append(
                BaysylBrief.Item(title: title, percent: percent(raw["percent"]), detail: string(raw["detail"]) ?? "")
            )
        }

        var test: BaysylBrief.Test?
        if let raw = root["test"] as? [String: Any], let title = string(raw["title"]) {
            test = BaysylBrief.Test(title: title, predict: string(raw["predict"]) ?? "")
        }

        return .success(
            BaysylBrief(
                updated: (root["updated"] as? String).flatMap(date(fromISO:)),
                headline: headline,
                items: items,
                test: test,
                today: string(root["today"])
            )
        )
    }

    /// A non-empty string, flattened to one line and capped. nil for anything else.
    static func string(_ value: Any?, limit: Int = maxStringLength) -> String? {
        guard let text = value as? String else { return nil }
        let flat = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return nil }
        return cap(flat, limit: limit)
    }

    /// Never longer than `limit` characters; a cut text ends in "…".
    static func cap(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// A whole number given as a JSON number (not true/false, not text).
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, abs(double) < 1_000_000, double == double.rounded() else { return nil }
        return Int(double)
    }

    /// 0 to 100 as a JSON number; a fraction is rounded. Anything else is "no percent".
    static func percent(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double <= 100 else { return nil }
        return Int(double.rounded())
    }

    static func date(fromISO text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

// MARK: - Watch payload

/// The part of a brief that is sent to the watch: fewer items and shorter text, to keep the payload small.
struct BaysylWatchBrief: Codable, Hashable, Sendable {
    struct Item: Codable, Hashable, Sendable {
        var title: String
        var percent: Int?
        var detail: String
    }

    static let maxItems = 4
    static let headlineLimit = 160
    static let titleLimit = 60
    static let detailLimit = 120
    static let lineLimit = 160

    var headline: String
    var items: [Item]
    var testTitle: String?
    var testPredict: String?
    var today: String?
    /// Seconds since 1970.
    var updated: TimeInterval?

    init(_ brief: BaysylBrief) {
        let cap = BaysylBriefDecoder.cap
        headline = cap(brief.headline, Self.headlineLimit)
        items = brief.items.prefix(Self.maxItems).map {
            Item(title: cap($0.title, Self.titleLimit), percent: $0.percent, detail: cap($0.detail, Self.detailLimit))
        }
        testTitle = brief.test.map { cap($0.title, Self.titleLimit) }
        testPredict = brief.test.map { cap($0.predict, Self.lineLimit) }
        today = brief.today.map { cap($0, Self.lineLimit) }
        updated = brief.updated?.timeIntervalSince1970
    }

    /// Property-list values only, under `WatchMessageKeys`. Absent parts are left out.
    var dictionary: [String: Any] {
        var result: [String: Any] = [
            WatchMessageKeys.baysylBriefHeadline: headline,
            WatchMessageKeys.baysylBriefItems: items.map { item -> [String: Any] in
                var entry: [String: Any] = [WatchMessageKeys.baysylBriefItemTitle: item.title]
                if let percent = item.percent { entry[WatchMessageKeys.baysylBriefItemPercent] = percent }
                if !item.detail.isEmpty { entry[WatchMessageKeys.baysylBriefItemDetail] = item.detail }
                return entry
            }
        ]
        if let testTitle { result[WatchMessageKeys.baysylBriefTestTitle] = testTitle }
        if let testPredict, !testPredict.isEmpty { result[WatchMessageKeys.baysylBriefTestPredict] = testPredict }
        if let today { result[WatchMessageKeys.baysylBriefToday] = today }
        if let updated { result[WatchMessageKeys.baysylBriefUpdated] = updated }
        return result
    }
}
