import Foundation
import Testing

@testable import Trio

/// Tests for the display-only Statistics "Reports" tab: decoding, ordering, and the cache.
/// Pure: the loader is an injected closure and the cache is a file in a temporary directory.
/// Nothing here touches the network, settings, the pump or Core Data.
@Suite("Reports tab tests") struct ReportsTabTests {
    // MARK: - Helpers

    private struct LoaderFailure: Error, LocalizedError {
        var errorDescription: String? { "offline for the test" }
    }

    private let source = "https://reports.example/reports.json"

    private let fullPayloadJSON = """
    {
      "updatedAt": "2026-11-20T06:00:00Z",
      "reports": [
        {
          "id": "night-2026-11-19",
          "date": "2026-11-19",
          "kind": "night",
          "title": "Night report",
          "summary": "Flat after midnight.",
          "sections": [
            {"heading": "What happened", "body": "Line one.\\nLine two."},
            {"heading": "Idea", "body": "Nothing to change."}
          ]
        },
        {
          "id": "settings-2026-11-20",
          "date": "2026-11-20",
          "kind": "settings",
          "title": "Settings table",
          "summary": "No changes.",
          "sections": []
        }
      ]
    }
    """

    private func data(_ json: String) -> Data { Data(json.utf8) }

    /// A cache file path inside a fresh temporary directory (the directory itself is not created,
    /// so the store's own directory creation is exercised).
    private func temporaryCacheURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ReportsTabTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("reports-cache.json")
    }

    private func removeCache(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - Decoding

    @Test("Decodes a full payload") func decodesFullPayload() throws {
        let payload = try AssistantReportsStore.decode(data(fullPayloadJSON))

        #expect(payload.updatedAt == "2026-11-20T06:00:00Z")
        #expect(payload.updatedAtDate == Date(timeIntervalSince1970: 1_795_154_400))
        #expect(payload.reports.count == 2)

        let night = try #require(payload.reports.first)
        #expect(night.id == "night-2026-11-19")
        #expect(night.date == "2026-11-19")
        #expect(night.kind == .night)
        #expect(night.kindRaw == "night")
        #expect(night.title == "Night report")
        #expect(night.summary == "Flat after midnight.")
        #expect(night.day != nil)
        #expect(night.sections.count == 2)
        #expect(night.sections[0].heading == "What happened")
        #expect(night.sections[0].body == "Line one.\nLine two.")
        #expect(night.sections[1] == AssistantReport.Section(heading: "Idea", body: "Nothing to change."))

        #expect(payload.reports[1].kind == .settings)
        #expect(payload.reports[1].sections.isEmpty)
    }

    @Test("Decodes with missing optional fields and ignores unknown fields") func decodesMissingOptionalFields() throws {
        let json = """
        {
          "futureTopLevelField": {"a": 1},
          "reports": [
            {"id": "a", "date": "2026-11-18", "extra": true},
            {"title": "No id", "kind": "weekly", "sections": [{"body": "Only a body"}, "not a section"]},
            "not a report",
            {"id": 7, "date": "2026-11-17", "kind": "NOTE", "summary": null}
          ]
        }
        """
        let payload = try AssistantReportsStore.decode(data(json))

        #expect(payload.updatedAt == nil)
        #expect(payload.updatedAtDate == nil)
        // The bare string is dropped; the three objects survive.
        #expect(payload.reports.count == 3)

        let first = payload.reports[0]
        #expect(first.id == "a")
        #expect(first.kind == .other)
        #expect(first.title.isEmpty)
        #expect(first.summary.isEmpty)
        #expect(first.sections.isEmpty)

        let second = payload.reports[1]
        #expect(!second.id.isEmpty)
        #expect(second.date.isEmpty)
        #expect(second.day == nil)
        #expect(second.kind == .other)
        #expect(second.kindLabel == "Weekly")
        #expect(second.sections == [AssistantReport.Section(heading: "", body: "Only a body")])

        let third = payload.reports[2]
        #expect(third.id == "7")
        #expect(third.kind == .note)
        #expect(third.summary.isEmpty)
    }

    @Test("Rejects documents that are not a reports file") func rejectsNonReportDocuments() {
        #expect(throws: AssistantReportsStore.StoreError.undecodable) {
            try AssistantReportsStore.decode(data("<html><body>Not found</body></html>"))
        }
        #expect(throws: AssistantReportsStore.StoreError.undecodable) {
            try AssistantReportsStore.decode(data("{\"status\": \"ok\"}"))
        }
        #expect(throws: AssistantReportsStore.StoreError.undecodable) {
            try AssistantReportsStore.decode(data("[]"))
        }
    }

    // MARK: - Ordering

    @Test("Sorts reports newest first and keeps sent order within a day") func sortsNewestFirst() {
        let payload = AssistantReportsPayload(reports: [
            AssistantReport(id: "old", date: "2026-11-01"),
            AssistantReport(id: "new-a", date: "2026-11-20"),
            AssistantReport(id: "undated", date: ""),
            AssistantReport(id: "mid", date: "2026-11-10"),
            AssistantReport(id: "new-b", date: "2026-11-20"),
            AssistantReport(id: "last-year", date: "2025-12-31")
        ])

        #expect(payload.sortedReports.map(\.id) == ["new-a", "new-b", "mid", "old", "last-year", "undated"])
    }

    // MARK: - Source URL

    @Test("Accepts only http and https source URLs") func validatesSourceURL() {
        #expect(
            AssistantReportsStore.validatedURL(from: "  https://reports.example/r.json \n")?.absoluteString
                == "https://reports.example/r.json"
        )
        #expect(AssistantReportsStore.validatedURL(from: "http://192.168.1.20:8080/reports.json") != nil)
        #expect(AssistantReportsStore.validatedURL(from: "") == nil)
        #expect(AssistantReportsStore.validatedURL(from: "reports.json") == nil)
        #expect(AssistantReportsStore.validatedURL(from: "file:///etc/hosts") == nil)
        #expect(AssistantReportsStore.validatedURL(from: "ftp://reports.example/r.json") == nil)
    }

    // MARK: - Cache

    @Test("Cache write then read returns the same snapshot") func cacheRoundTrip() throws {
        let cacheURL = temporaryCacheURL()
        defer { removeCache(cacheURL) }
        let store = AssistantReportsStore(cacheFileURL: cacheURL, loader: { _ in throw LoaderFailure() })

        #expect(store.loadCached(for: source) == nil)

        let snapshot = AssistantReportsStore.Snapshot(
            payload: try AssistantReportsStore.decode(data(fullPayloadJSON)),
            fetchedAt: Date(timeIntervalSince1970: 1_795_154_400),
            source: source
        )
        try store.writeCache(snapshot)

        #expect(store.loadCached(for: source) == snapshot)
        // Surrounding whitespace in the typed URL does not hide the cache.
        #expect(store.loadCached(for: " \(source) ") == snapshot)
        // A cache fetched from another source is not shown for this one.
        #expect(store.loadCached(for: "https://other.example/reports.json") == nil)
    }

    @Test("A successful refresh returns fresh reports and writes the cache") func refreshWritesCache() async throws {
        let cacheURL = temporaryCacheURL()
        defer { removeCache(cacheURL) }
        let fetchedAt = Date(timeIntervalSince1970: 1_795_154_400)
        let body = data(fullPayloadJSON)
        let store = AssistantReportsStore(
            cacheFileURL: cacheURL,
            loader: { url in
                #expect(url.absoluteString == "https://reports.example/reports.json")
                return body
            },
            now: { fetchedAt }
        )

        let result = await store.refresh(from: source)

        #expect(result.isFresh)
        #expect(result.errorMessage == nil)
        let snapshot = try #require(result.snapshot)
        #expect(snapshot.fetchedAt == fetchedAt)
        #expect(snapshot.payload.sortedReports.map(\.id) == ["settings-2026-11-20", "night-2026-11-19"])
        #expect(store.loadCached(for: source) == snapshot)
    }

    @Test("A failing loader keeps the cached reports") func loaderFailureKeepsCache() async throws {
        let cacheURL = temporaryCacheURL()
        defer { removeCache(cacheURL) }
        let body = data(fullPayloadJSON)

        let online = AssistantReportsStore(cacheFileURL: cacheURL, loader: { _ in body })
        let first = await online.refresh(from: source)
        let cached = try #require(first.snapshot)

        let offline = AssistantReportsStore(cacheFileURL: cacheURL, loader: { _ in throw LoaderFailure() })
        let second = await offline.refresh(from: source)

        #expect(!second.isFresh)
        #expect(second.errorMessage == "offline for the test")
        #expect(second.snapshot == cached)
        #expect(second.snapshot?.payload.reports.count == 2)
        // The file on disk is untouched by the failure.
        #expect(offline.loadCached(for: source) == cached)
    }

    @Test("A bad document from the loader keeps the cached reports") func badDocumentKeepsCache() async throws {
        let cacheURL = temporaryCacheURL()
        defer { removeCache(cacheURL) }
        let body = data(fullPayloadJSON)

        let good = AssistantReportsStore(cacheFileURL: cacheURL, loader: { _ in body })
        let firstResult = await good.refresh(from: source)
        let cached = try #require(firstResult.snapshot)

        let bad = AssistantReportsStore(cacheFileURL: cacheURL, loader: { _ in Data("<html>502</html>".utf8) })
        let result = await bad.refresh(from: source)

        #expect(!result.isFresh)
        #expect(result.errorMessage != nil)
        #expect(result.snapshot == cached)
    }

    @Test("A failure with no cache returns no reports and a message, without calling out for a bad URL") func failureWithoutCache() async {
        let cacheURL = temporaryCacheURL()
        defer { removeCache(cacheURL) }
        let store = AssistantReportsStore(cacheFileURL: cacheURL, loader: { _ in
            Issue.record("The loader must not be called for an invalid URL")
            return Data()
        })

        let result = await store.refresh(from: "not a url")

        #expect(!result.isFresh)
        #expect(result.snapshot == nil)
        #expect(result.errorMessage != nil)
    }
}
