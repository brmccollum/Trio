import Foundation

// Display-only models for the Statistics "Reports" tab.
// Nothing in this folder reads or writes settings, treatments, glucose, pump or loop state.

/// One analysis report written outside the app and shown read-only in Statistics.
struct AssistantReport: Codable, Equatable, Hashable, Identifiable {
    /// The known report kinds. Anything else decodes as `.other` and is shown with its raw text.
    enum Kind: String {
        case night
        case day
        case test
        case settings
        case note
        case other

        var displayName: String {
            switch self {
            case .night: return String(localized: "Night", comment: "Report kind tag")
            case .day: return String(localized: "Day", comment: "Report kind tag")
            case .test: return String(localized: "Test", comment: "Report kind tag")
            case .settings: return String(localized: "Settings", comment: "Report kind tag")
            case .note: return String(localized: "Note", comment: "Report kind tag")
            case .other: return String(localized: "Other", comment: "Report kind tag")
            }
        }
    }

    struct Section: Codable, Equatable, Hashable {
        var heading: String
        var body: String

        init(heading: String = "", body: String = "") {
            self.heading = heading
            self.body = body
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            heading = container.lenientString(.heading) ?? ""
            body = container.lenientString(.body) ?? ""
        }
    }

    var id: String
    /// Local calendar day as `YYYY-MM-DD`. Kept as text; it is only sorted and displayed.
    var date: String
    /// Raw kind text from the payload.
    var kindRaw: String
    var title: String
    var summary: String
    var sections: [Section]

    var kind: Kind { Kind(rawValue: kindRaw.lowercased()) ?? .other }

    /// Text for the kind tag: the known name, or the raw text for a kind this build does not know.
    var kindLabel: String {
        if kind == .other, !kindRaw.isEmpty { return kindRaw.capitalized }
        return kind.displayName
    }

    /// `date` parsed as a local calendar day, or nil when it is not `YYYY-MM-DD`.
    var day: Date? { Self.dayFormatter.date(from: date) }

    /// `date` formatted for display, falling back to the raw text.
    var displayDate: String {
        guard let day else { return date }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    enum CodingKeys: String, CodingKey {
        case id
        case date
        case kindRaw = "kind"
        case title
        case summary
        case sections
    }

    init(
        id: String,
        date: String = "",
        kind: String = "",
        title: String = "",
        summary: String = "",
        sections: [Section] = []
    ) {
        self.id = id
        self.date = date
        kindRaw = kind
        self.title = title
        self.summary = summary
        self.sections = sections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = container.lenientString(.date) ?? ""
        kindRaw = container.lenientString(.kindRaw) ?? ""
        title = container.lenientString(.title) ?? ""
        summary = container.lenientString(.summary) ?? ""
        sections = (try? container.decodeIfPresent(LossyArray<Section>.self, forKey: .sections))?.elements ?? []
        // A report without an id still needs a stable identity for the list.
        id = container.lenientString(.id) ?? "\(date)|\(kindRaw)|\(title)"
    }
}

/// The JSON document served by the report source.
struct AssistantReportsPayload: Codable, Equatable {
    /// ISO 8601 text, as sent. Parsed on demand by `updatedAtDate`.
    var updatedAt: String?
    var reports: [AssistantReport]

    init(updatedAt: String? = nil, reports: [AssistantReport] = []) {
        self.updatedAt = updatedAt
        self.reports = reports
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = container.lenientString(.updatedAt)
        reports = (try? container.decodeIfPresent(LossyArray<AssistantReport>.self, forKey: .reports))?.elements ?? []
    }

    /// Reports newest first by `date`. Reports sharing a date keep the order they were sent in.
    var sortedReports: [AssistantReport] {
        reports.enumerated()
            .sorted { lhs, rhs in
                lhs.element.date != rhs.element.date ? lhs.element.date > rhs.element.date : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    var updatedAtDate: Date? {
        guard let updatedAt else { return nil }
        return Self.parseISO8601(updatedAt)
    }

    /// Accepts ISO 8601 with or without fractional seconds, and without a zone (read as local time).
    static func parseISO8601(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }

        let local = DateFormatter()
        local.calendar = Calendar(identifier: .gregorian)
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }
}

// MARK: - Lenient decoding helpers

/// Decodes an array and drops elements that fail to decode instead of failing the whole document.
private struct LossyArray<Element: Decodable>: Decodable {
    private struct Skipped: Decodable {}

    var elements: [Element] = []

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                // Advance past the bad element; a failed decode does not move the index.
                _ = try container.decode(Skipped.self)
            }
        }
    }
}

private extension KeyedDecodingContainer {
    /// A string for the key, accepting a number in its place; nil when missing, null or another type.
    func lenientString(_ key: Key) -> String? {
        if let string = try? decodeIfPresent(String.self, forKey: key) { return string }
        if let integer = try? decodeIfPresent(Int.self, forKey: key) { return String(integer) }
        if let double = try? decodeIfPresent(Double.self, forKey: key) { return String(double) }
        return nil
    }
}
