import Foundation

/// Fetches the reports document with a plain GET and keeps the last good copy in a cache file.
///
/// Display only: one outbound GET to a URL the user typed on the Reports tab, and one file in the
/// Caches directory. It has no access to settings, storage, the pump, the CGM or Nightscout.
/// It never retries on its own; every fetch is started by the view (on appear or pull to refresh).
struct AssistantReportsStore: Sendable {
    /// Loads the raw document for a URL. Injected so tests run without the network.
    typealias Loader = @Sendable(URL) async throws -> Data

    /// UserDefaults key holding the source URL typed on the Reports tab.
    static let sourceURLDefaultsKey = "bryan.reports.sourceURL"
    static let requestTimeout: TimeInterval = 15
    /// Upper bound on an accepted document, so a wrong URL cannot fill memory or the cache.
    static let maximumDocumentBytes = 5 * 1024 * 1024

    /// What the view shows: a decoded document, when it was fetched, and where from.
    struct Snapshot: Codable, Equatable {
        var payload: AssistantReportsPayload
        var fetchedAt: Date
        var source: String
    }

    enum StoreError: Error, Equatable, LocalizedError {
        case invalidURL
        case badStatus(Int)
        case tooLarge
        case undecodable

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return String(localized: "The source URL is not a valid http or https address.")
            case let .badStatus(code):
                return String(localized: "The source answered with status \(code).")
            case .tooLarge:
                return String(localized: "The source sent more data than a reports file should have.")
            case .undecodable:
                return String(localized: "The source did not send a reports file.")
            }
        }
    }

    /// The outcome of one refresh. `snapshot` is what to show now: fresh on success, otherwise the
    /// cached copy (nil when there is none). `errorMessage` is nil on success.
    struct RefreshResult: Equatable {
        var snapshot: Snapshot?
        var errorMessage: String?
        var isFresh: Bool
    }

    let cacheFileURL: URL
    private let loader: Loader
    private let now: @Sendable() -> Date

    init(
        cacheFileURL: URL = AssistantReportsStore.defaultCacheFileURL,
        loader: @escaping Loader = AssistantReportsStore.networkLoader,
        now: @escaping @Sendable() -> Date = { Date() }
    ) {
        self.cacheFileURL = cacheFileURL
        self.loader = loader
        self.now = now
    }

    // MARK: - URL handling

    /// Trims the text and accepts only absolute http/https URLs with a host.
    static func validatedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return nil }
        return url
    }

    // MARK: - Decoding

    static func decode(_ data: Data) throws -> AssistantReportsPayload {
        guard data.count <= maximumDocumentBytes else { throw StoreError.tooLarge }
        // Require a JSON object that has a `reports` array, so an HTML error page or an unrelated
        // JSON document is reported as an error instead of replacing good cached reports with nothing.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["reports"] is [Any],
              let payload = try? JSONDecoder().decode(AssistantReportsPayload.self, from: data)
        else { throw StoreError.undecodable }
        return payload
    }

    // MARK: - Cache

    /// The cached snapshot for this source, or nil when there is none, it is unreadable, or it was
    /// fetched from a different source.
    func loadCached(for source: String) -> Snapshot? {
        guard let data = try? Data(contentsOf: cacheFileURL),
              let snapshot = try? Self.cacheDecoder.decode(Snapshot.self, from: data),
              snapshot.source == Self.normalized(source)
        else { return nil }
        return snapshot
    }

    func writeCache(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(
            at: cacheFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try Self.cacheEncoder.encode(snapshot)
        try data.write(to: cacheFileURL, options: .atomic)
    }

    // MARK: - Refresh

    /// One fetch attempt, no retries. Never throws: a failure comes back as a message next to
    /// whatever is cached for this source.
    func refresh(from source: String) async -> RefreshResult {
        guard let url = Self.validatedURL(from: source) else {
            return failure(StoreError.invalidURL, source: source)
        }
        do {
            let data = try await loader(url)
            let payload = try Self.decode(data)
            // Whole seconds, so the snapshot returned here equals the one read back from the cache file.
            let fetchedAt = Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down))
            let snapshot = Snapshot(payload: payload, fetchedAt: fetchedAt, source: Self.normalized(source))
            // A cache write failure only costs offline viewing later; still show the fresh reports.
            try? writeCache(snapshot)
            return RefreshResult(snapshot: snapshot, errorMessage: nil, isFresh: true)
        } catch {
            return failure(error, source: source)
        }
    }

    private func failure(_ error: Error, source: String) -> RefreshResult {
        RefreshResult(
            snapshot: loadCached(for: source),
            errorMessage: Self.message(for: error),
            isFresh: false
        )
    }

    static func message(for error: Error) -> String {
        if let storeError = error as? StoreError, let description = storeError.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private static func normalized(_ source: String) -> String {
        source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Defaults

    static var defaultCacheFileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("AssistantReports", isDirectory: true)
            .appendingPathComponent("reports-cache.json")
    }

    /// Plain GET with a 15 second limit: no auth header, no cookies, no URL cache.
    static let networkLoader: Loader = { url in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw StoreError.badStatus(http.statusCode)
        }
        return data
    }

    private static var cacheEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static var cacheDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
