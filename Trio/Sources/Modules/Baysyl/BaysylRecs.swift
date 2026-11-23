import Foundation

/// A snapshot of Baysyl's recommendations, bundled into a private build as `BaysylRecs.json`.
///
/// Display only. Nothing here is read by the algorithm, the pump, the CGM or any upload; the app
/// shows the text and that is all. The file is optional: a normal build has none.
///
/// Shape: `{"asOf": "2026-11-22", "note": "...", "recs": [{"title": "...", "confidence": 85, "why": "...", "next": "..."}]}`
struct BaysylRecs: Equatable {
    struct Rec: Equatable, Identifiable {
        let id: Int
        let title: String
        /// 0...100, or nil when the file gave none.
        let confidence: Int?
        let why: String
        let next: String
    }

    /// As written in the file (normally `yyyy-MM-dd`); empty when missing.
    let asOf: String
    let note: String
    let recs: [Rec]

    /// `asOf` as a readable date when it is a plain `yyyy-MM-dd`, otherwise the text as written.
    var displayAsOf: String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: asOf) else { return asOf }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

extension BaysylRecs: Decodable {
    private enum CodingKeys: String, CodingKey {
        case asOf
        case note
        case recs
    }

    private struct RawRec: Decodable {
        let title: String?
        let confidence: Double?
        let why: String?
        let next: String?

        private enum CodingKeys: String, CodingKey {
            case title
            case confidence
            case why
            case next
        }

        /// Lenient: a field of the wrong type reads as missing instead of failing the whole file.
        init(from decoder: Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            title = try? container?.decodeIfPresent(String.self, forKey: .title)
            why = try? container?.decodeIfPresent(String.self, forKey: .why)
            next = try? container?.decodeIfPresent(String.self, forKey: .next)
            if let number = try? container?.decodeIfPresent(Double.self, forKey: .confidence) {
                confidence = number
            } else if let text = try? container?.decodeIfPresent(String.self, forKey: .confidence) {
                confidence = Double(text.trimmingCharacters(in: CharacterSet(charactersIn: " %")))
            } else {
                confidence = nil
            }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        asOf = ((try? container.decodeIfPresent(String.self, forKey: .asOf)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        note = ((try? container.decodeIfPresent(String.self, forKey: .note)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // `recs` must be an array; that is what makes a document a recommendations file.
        let raw = try container.decode([RawRec].self, forKey: .recs)
        var kept: [Rec] = []
        for item in raw {
            let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // An entry with no title has nothing to show.
            guard !title.isEmpty else { continue }
            kept.append(Rec(
                id: kept.count,
                title: title,
                confidence: Self.clampedConfidence(item.confidence),
                why: (item.why ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                next: (item.next ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        recs = kept
    }

    /// Rounds to a whole percent and clamps to 0...100; nil stays nil, as does anything not finite.
    static func clampedConfidence(_ value: Double?) -> Int? {
        guard let value, value.isFinite else { return nil }
        return Int(min(max(value.rounded(), 0), 100))
    }
}

/// Reads the optional bundled recommendations file. Never throws to the caller and never touches the network.
enum BaysylRecsLoader {
    static let resourceName = "BaysylRecs"
    static let resourceExtension = "json"
    /// Larger than any real file; guards against something unexpected being bundled.
    static let maximumBytes = 256 * 1024

    enum LoadResult: Equatable {
        case loaded(BaysylRecs)
        /// No file in this build: the normal case for a stock build.
        case absent
        /// A file is there but is not a recommendations document.
        case unreadable
    }

    enum DecodeError: Error, Equatable {
        case tooLarge
        case malformed
    }

    static func decode(_ data: Data) throws -> BaysylRecs {
        guard data.count <= maximumBytes else { throw DecodeError.tooLarge }
        guard let recs = try? JSONDecoder().decode(BaysylRecs.self, from: data) else { throw DecodeError.malformed }
        return recs
    }

    static func load(from url: URL?) -> LoadResult {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url), let recs = try? decode(data) else { return .unreadable }
        return .loaded(recs)
    }

    static func load(bundle: Bundle = .main) -> LoadResult {
        load(from: bundle.url(forResource: resourceName, withExtension: resourceExtension))
    }

    /// True when this build carries a recommendations file, readable or not.
    static var isBundled: Bool {
        Bundle.main.url(forResource: resourceName, withExtension: resourceExtension) != nil
    }
}
