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

/// Tests for the optional top-level `links` of the reports payload. Pure decoding and validation.
@Suite("Reports tab link tests") struct ReportsTabLinkTests {
    private func payload(_ json: String) throws -> AssistantReportsPayload {
        try AssistantReportsStore.decode(Data(json.utf8))
    }

    @Test("A payload without links decodes with none") func decodesWithoutLinks() throws {
        let decoded = try payload(#"{"reports": []}"#)
        #expect(decoded.links.isEmpty)
        #expect(decoded.openableLinks.isEmpty)
    }

    @Test("Links decode in order with title and url") func decodesLinks() throws {
        let decoded = try payload("""
        {"reports": [], "links": [
          {"title": "Dashboard", "url": "https://example.com/basal"},
          {"title": "Change log", "url": "http://example.org/log?x=1"}
        ]}
        """)
        #expect(decoded.links.count == 2)
        #expect(decoded.openableLinks.map(\.displayTitle) == ["Dashboard", "Change log"])
        #expect(decoded.openableLinks.first?.destination == URL(string: "https://example.com/basal"))
    }

    @Test("Malformed links are tolerated, not fatal") func lenientLinks() throws {
        let decoded = try payload("""
        {"reports": [{"id": "a", "title": "Kept"}], "links": [
          "not an object", 7, null,
          {"title": 12, "url": "https://example.com/a"},
          {"url": "https://example.com/untitled"},
          {"title": "No address"}
        ]}
        """)
        #expect(decoded.reports.count == 1)
        #expect(decoded.openableLinks.map(\.displayTitle) == ["12", "example.com"])

        let wrongType = try payload(#"{"reports": [], "links": "nope"}"#)
        #expect(wrongType.links.isEmpty)
    }

    @Test("Only http and https addresses are openable", arguments: [
        "javascript:alert(1)",
        "file:///etc/passwd",
        "tel:5551234",
        "trio://device-select-resp",
        "ftp://example.com/x",
        "data:text/html,hi",
        "example.com/no-scheme",
        "https://",
        ""
    ]) func rejectsOtherSchemes(url: String) {
        let link = AssistantReportLink(title: "Bad", url: url)
        #expect(link.destination == nil)
        #expect(AssistantReportsPayload(links: [link]).openableLinks.isEmpty)
    }

    @Test("http and https are accepted, case and whitespace aside") func acceptsWebSchemes() {
        #expect(AssistantReportLink(title: "a", url: " HTTPS://Example.com/x ").destination != nil)
        #expect(AssistantReportLink(title: "b", url: "http://example.com").destination != nil)
    }

    @Test("Links are cached with the rest of the snapshot") func linksAreCached() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reports-link-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = "https://reports.example/reports.json"
        let json = #"{"reports": [], "links": [{"title": "Dashboard", "url": "https://example.com/basal"}]}"#
        let store = AssistantReportsStore(
            cacheFileURL: directory.appendingPathComponent("cache.json"),
            loader: { _ in Data(json.utf8) }
        )

        let fresh = await store.refresh(from: source)
        #expect(fresh.isFresh)
        let cached = store.loadCached(for: source)
        #expect(cached == fresh.snapshot)
        #expect(cached?.payload.openableLinks.first?.displayTitle == "Dashboard")
    }
}

/// Precedence between the source typed on the Reports tab and the build-time default.
@Suite("Reports tab default source tests") struct ReportsTabDefaultSourceTests {
    private let bundled = "https://default.example/reports.json"

    @Test("A typed source wins over the build-time default") func typedWins() {
        let source = AssistantReportsStore.effectiveSource(stored: " https://typed.example/r.json ", bundledDefault: bundled)
        #expect(source == "https://typed.example/r.json")
    }

    @Test("Unset or blank falls back to the build-time default", arguments: ["", "   ", "\n"]) func fallsBack(stored: String) {
        #expect(AssistantReportsStore.effectiveSource(stored: stored, bundledDefault: " \(bundled) ") == bundled)
    }

    @Test("No default and nothing typed means no source", arguments: [
        "",
        "  ",
        "$(BRYAN_REPORTS_SOURCE_URL)"
    ]) func noSource(bundledDefault: String) {
        #expect(AssistantReportsStore.effectiveSource(stored: "", bundledDefault: bundledDefault) == "")
    }
}

/// The build-time "Open Basal" link and the local-network hint.
@Suite("Reports tab link validation tests") struct ReportsTabURLValidationTests {
    @Test("Only https is accepted for the Basal link", arguments: [
        "http://example.com/basal",
        "javascript:alert(1)",
        "example.com/basal",
        "https://",
        "$(BRYAN_BASAL_URL)",
        ""
    ]) func rejectsNonHTTPS(text: String) {
        #expect(AssistantReportsStore.validatedHTTPSURL(from: text) == nil)
    }

    @Test("A plain https address is accepted") func acceptsHTTPS() {
        #expect(AssistantReportsStore.validatedHTTPSURL(from: " https://example.com/basal ")?.host == "example.com")
    }

    @Test("Local network sources are recognised", arguments: [
        "http://my-mac.local:8080/reports.json",
        "http://192.168.1.20/r.json",
        "http://10.0.0.5:9000/r.json",
        "http://172.20.1.1/r.json",
        "http://localhost:8765/r.json"
    ]) func local(source: String) {
        #expect(AssistantReportsStore.isLocalNetworkSource(source))
    }

    @Test("Internet sources are not", arguments: [
        "https://example.com/reports.json",
        "http://172.32.0.1/r.json",
        "https://8.8.8.8/r.json",
        "not a url"
    ]) func notLocal(source: String) {
        #expect(!AssistantReportsStore.isLocalNetworkSource(source))
    }
}
