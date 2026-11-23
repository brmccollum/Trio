import Foundation
import Testing

@testable import Trio

/// Tests for the display-only "Baysyl recommends" screen data: decoding the optional bundled file.
/// Pure: files live in a temporary directory. Nothing here touches the network, settings, the pump or Core Data.
/// All text is invented placeholder text.
@Suite("Baysyl recommendations tests") struct BaysylRecsTests {
    private let fullJSON = """
    {
      "asOf": "2026-11-22",
      "note": "Placeholder note for the test.",
      "recs": [
        {"title": "Placeholder one", "confidence": 85, "why": "Placeholder why.", "next": "Placeholder next."},
        {"title": "Placeholder two", "confidence": 40, "why": "Another why.", "next": "Another next."}
      ]
    }
    """

    private func temporaryFile(_ contents: Data?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BaysylRecsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("BaysylRecs.json")
        if let contents { try contents.write(to: url) }
        return url
    }

    // MARK: - Present

    @Test("Decodes a full file") func decodesFull() throws {
        let recs = try BaysylRecsLoader.decode(Data(fullJSON.utf8))
        #expect(recs.asOf == "2026-11-22")
        #expect(recs.note == "Placeholder note for the test.")
        #expect(recs.recs.count == 2)
        #expect(recs.recs[0].title == "Placeholder one")
        #expect(recs.recs[0].confidence == 85)
        #expect(recs.recs[0].why == "Placeholder why.")
        #expect(recs.recs[0].next == "Placeholder next.")
        #expect(recs.recs[1].confidence == 40)
        #expect(recs.recs.map(\.id) == [0, 1])
    }

    @Test("A file on disk loads") func loadsFromFile() throws {
        let url = try temporaryFile(Data(fullJSON.utf8))
        guard case let .loaded(recs) = BaysylRecsLoader.load(from: url) else {
            Issue.record("expected the file to load")
            return
        }
        #expect(recs.recs.count == 2)
    }

    @Test("Optional fields may be missing, and unknown fields are ignored") func decodesSparse() throws {
        let json = #"{"recs": [{"title": "Only a title", "extra": true}], "somethingElse": 1}"#
        let recs = try BaysylRecsLoader.decode(Data(json.utf8))
        #expect(recs.asOf.isEmpty)
        #expect(recs.note.isEmpty)
        #expect(recs.recs.count == 1)
        #expect(recs.recs[0].confidence == nil)
        #expect(recs.recs[0].why.isEmpty)
        #expect(recs.recs[0].next.isEmpty)
    }

    @Test("An empty list is a valid file") func decodesEmptyList() throws {
        let recs = try BaysylRecsLoader.decode(Data(#"{"asOf": "2026-11-22", "recs": []}"#.utf8))
        #expect(recs.recs.isEmpty)
    }

    @Test("Entries without a title are dropped; odd field types do not sink the file") func lenientEntries() throws {
        let json = """
        {"recs": [
          {"title": "  ", "confidence": 90},
          {"confidence": 90},
          {"title": "Kept", "confidence": "72%", "why": 5, "next": null},
          "not an object",
          {"title": "Also kept", "confidence": 61.6}
        ]}
        """
        let recs = try BaysylRecsLoader.decode(Data(json.utf8))
        #expect(recs.recs.map(\.title) == ["Kept", "Also kept"])
        #expect(recs.recs[0].confidence == 72)
        #expect(recs.recs[0].why.isEmpty)
        #expect(recs.recs[1].confidence == 62)
    }

    @Test("Confidence is rounded and clamped to 0...100", arguments: [
        (-5.0, 0), (0.0, 0), (49.4, 49), (99.5, 100), (250.0, 100)
    ]) func clampsConfidence(input: Double, expected: Int) {
        #expect(BaysylRecs.clampedConfidence(input) == expected)
    }

    @Test("No confidence stays nil") func nilConfidence() {
        #expect(BaysylRecs.clampedConfidence(nil) == nil)
        #expect(BaysylRecs.clampedConfidence(.nan) == nil)
    }

    @Test("Badge levels", arguments: [
        (100, BaysylConfidenceBadge.Level.high), (80, .high), (79, .medium), (50, .medium), (49, .low), (0, .low)
    ]) func badgeLevels(confidence: Int, level: BaysylConfidenceBadge.Level) {
        #expect(BaysylConfidenceBadge.level(for: confidence) == level)
    }

    @Test("A yyyy-MM-dd date is shown as a date; anything else is shown as written") func displayDate() throws {
        let dated = try BaysylRecsLoader.decode(Data(#"{"asOf": "2026-11-22", "recs": []}"#.utf8))
        #expect(dated.displayAsOf != "2026-11-22")
        #expect(dated.displayAsOf.contains("2026"))
        let free = try BaysylRecsLoader.decode(Data(#"{"asOf": "this morning", "recs": []}"#.utf8))
        #expect(free.displayAsOf == "this morning")
    }

    // MARK: - Absent

    @Test("No file means absent, not an error") func absentFile() throws {
        let url = try temporaryFile(nil)
        #expect(BaysylRecsLoader.load(from: url) == .absent)
        #expect(BaysylRecsLoader.load(from: nil) == .absent)
    }

    @Test("A bundle without the resource means absent") func absentInBundle() {
        // The test bundle never carries BaysylRecs.json.
        #expect(BaysylRecsLoader.load(bundle: Bundle(for: BundleMarker.self)) == .absent)
    }

    // MARK: - Malformed

    @Test("Malformed documents are rejected", arguments: [
        "",
        "not json",
        "<html><body>Not found</body></html>",
        "[]",
        "{}",
        #"{"asOf": "2026-11-22"}"#,
        #"{"recs": "none"}"#,
        #"{"recs": {"title": "x"}}"#,
        #"{"recs": [{"title": "x"}"#
    ]) func rejectsMalformed(text: String) {
        #expect(throws: BaysylRecsLoader.DecodeError.malformed) {
            try BaysylRecsLoader.decode(Data(text.utf8))
        }
    }

    @Test("A malformed file on disk is unreadable, not a crash") func unreadableFile() throws {
        let url = try temporaryFile(Data("{ definitely not json".utf8))
        #expect(BaysylRecsLoader.load(from: url) == .unreadable)
    }

    @Test("An oversized file is refused") func tooLarge() {
        let big = Data(repeating: UInt8(ascii: " "), count: BaysylRecsLoader.maximumBytes + 1)
        #expect(throws: BaysylRecsLoader.DecodeError.tooLarge) {
            try BaysylRecsLoader.decode(big)
        }
    }
}

private final class BundleMarker {}

/// The build-time Baysyl link.
@Suite("Baysyl link tests") struct BaysylLinkTests {
    @Test("Only https is accepted", arguments: [
        "http://example.com/page",
        "javascript:alert(1)",
        "example.com/page",
        "https://",
        "$(BRYAN_BASAL_URL)",
        "   ",
        ""
    ]) func rejectsNonHTTPS(text: String) {
        #expect(BaysylLink.validatedHTTPSURL(from: text) == nil)
    }

    @Test("A plain https address is accepted, whitespace aside") func acceptsHTTPS() {
        #expect(BaysylLink.validatedHTTPSURL(from: " https://example.com/page \n")?.host == "example.com")
    }

    @Test("The doorway and the empty state say what the task asked for") func fixedText() {
        #expect(BaysylRecsView.emptyMessage == "No recommendations bundled in this build. Open Baysyl for the live list.")
        #expect(!StatReportsView.doorwayText.isEmpty)
    }
}
