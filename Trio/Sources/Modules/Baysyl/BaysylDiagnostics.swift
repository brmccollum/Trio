import Foundation
import MetricKit

// MetricKit diagnostics for the private build: crash, hang, CPU-exception and disk-write-exception reports,
// plus the daily app-exit counts.
//
// Reporting only. Each diagnostic payload is saved as a file the user can share with "Share Logs", and a short
// text summary goes to the user's own Nightscout as an inert Note starting "Trio diagnostic:". The summary holds
// only what the system reported about the app's own code (kind, build, exception numbers, termination reason,
// binary+offset frames). No glucose, insulin or personal data.
//
// Everything works on the payload's JSON through optional casts, so a field that is missing or has another
// shape is skipped. Nothing here force-unwraps, uses `try!`, or converts a number that has not been checked.

// MARK: - Summary (pure)

enum BaysylDiagnosticSummary {
    static let prefix = "Trio diagnostic:"
    static let maxNotesPerPayload = 3
    static let frameLimit = 12
    static let fieldLimit = 160
    /// With frames of the app's own binaries on the busiest path: this many of them, and this many system frames.
    static let appFrameLimit = 8
    static let systemFrameLimit = 4
    /// With no app frame at all, a long stack is shown as its first few frames (which thread and process it is)
    /// and its deepest ones (where the time went): `outerFrameLimit` + the rest of `frameLimit`.
    static let outerFrameLimit = 4
    /// Guards against a malformed or enormous tree; a real stack is far shallower.
    static let maxDepth = 4000
    static let cpuLabel = "cpu exception"

    /// One frame of a call stack tree. `isApp` is true when its binary ships inside the app bundle.
    struct Frame: Equatable {
        let name: String
        let offset: String
        let isApp: Bool

        var text: String { "\(name)+\(offset)" }
    }

    /// One summary and the kind of diagnostic it describes ("crash", "hang", "cpu exception", ...).
    struct Labelled: Equatable {
        let label: String
        let text: String
    }

    /// Names of the binaries that ship inside the app bundle: the app itself, its extensions and its embedded
    /// frameworks. Frames in these are "our code"; everything else is the system.
    static let bundledBinaryNames: Set<String> = {
        var names = Set<String>()
        let main = Bundle.main
        if let name = main.executableURL?.lastPathComponent, !name.isEmpty { names.insert(name) }
        for case let directory? in [main.builtInPlugInsURL, main.privateFrameworksURL] {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }
            for item in items where item.pathExtension == "appex" || item.pathExtension == "framework" {
                let fallback = item.deletingPathExtension().lastPathComponent
                let name = Bundle(url: item)?.executableURL?.lastPathComponent ?? fallback
                if !name.isEmpty { names.insert(name) }
            }
        }
        return names
    }()

    /// One entry per kind of diagnostic in a payload, in the order they are reported.
    private static let kinds: [(key: String, label: String)] = [
        ("crashDiagnostics", "crash"),
        ("hangDiagnostics", "hang"),
        ("cpuExceptionDiagnostics", cpuLabel),
        ("diskWriteExceptionDiagnostics", "disk write exception")
    ]

    /// Summaries for one `MXDiagnosticPayload` JSON: at most `maxNotesPerPayload`, each at most `limit` characters.
    /// `fallbackBuild` is used when the payload does not name the build.
    static func summaries(
        payloadJSON: Data,
        fallbackBuild: String,
        limit: Int = BaysylLaunchReport.noteLimit,
        appBinaries: Set<String> = bundledBinaryNames,
        appBundleID: String? = Bundle.main.bundleIdentifier
    ) -> [String] {
        labelledSummaries(
            payloadJSON: payloadJSON,
            fallbackBuild: fallbackBuild,
            limit: limit,
            appBinaries: appBinaries,
            appBundleID: appBundleID
        ).map(\.text)
    }

    /// The same summaries, each with the kind of diagnostic it describes (used to limit how often one kind is sent).
    static func labelledSummaries(
        payloadJSON: Data,
        fallbackBuild: String,
        limit: Int = BaysylLaunchReport.noteLimit,
        appBinaries: Set<String> = bundledBinaryNames,
        appBundleID: String? = Bundle.main.bundleIdentifier
    ) -> [Labelled] {
        guard let root = (try? JSONSerialization.jsonObject(with: payloadJSON)) as? [String: Any] else { return [] }

        var all: [Labelled] = []
        for kind in kinds {
            guard let diagnostics = root[kind.key] as? [Any] else { continue }
            for case let diagnostic as [String: Any] in diagnostics {
                let text = summary(
                    of: diagnostic,
                    label: kind.label,
                    fallbackBuild: fallbackBuild,
                    appBinaries: appBinaries,
                    appBundleID: appBundleID
                )
                all.append(Labelled(label: kind.label, text: text))
            }
        }
        guard !all.isEmpty else { return [] }

        var kept = Array(all.prefix(maxNotesPerPayload))
        let dropped = all.count - kept.count
        if dropped > 0, let last = kept.popLast() {
            let suffix = " (+\(dropped) more in the saved file)"
            let text = BaysylLaunchReport.truncate(last.text, limit: max(0, limit - suffix.count)) + suffix
            kept.append(Labelled(label: last.label, text: text))
        }
        return kept.map { Labelled(label: $0.label, text: BaysylLaunchReport.truncate($0.text, limit: limit)) }
    }

    static func summary(
        of diagnostic: [String: Any],
        label: String,
        fallbackBuild: String,
        appBinaries: Set<String> = bundledBinaryNames,
        appBundleID: String? = Bundle.main.bundleIdentifier
    ) -> String {
        let meta = diagnostic["diagnosticMetaData"] as? [String: Any] ?? [:]
        var parts: [String] = ["\(prefix) \(label)"]

        let version = text(meta["appVersion"])
        let build = text(meta["appBuildVersion"])
        if version != nil || build != nil {
            parts.append("build \(version ?? "?") (\(build ?? "?"))")
        } else {
            parts.append("build \(fallbackBuild)")
        }
        // Which process the report is about, without ever printing the bundle identifier itself.
        if let process = processLabel(reported: text(meta["bundleIdentifier"]), appBundleID: appBundleID) {
            parts.append("process \(process)")
        }

        let numbered: [(String, String)] = [
            ("exceptionType", "exception type"),
            ("exceptionCode", "code"),
            ("signal", "signal"),
            ("terminationReason", "termination"),
            ("hangDuration", "hang duration"),
            ("totalCPUTime", "cpu time"),
            ("totalSampledTime", "sampled time"),
            ("writesCaused", "writes"),
            ("osVersion", "os")
        ]
        for (key, name) in numbered {
            if let value = text(meta[key]) { parts.append("\(name) \(value)") }
        }
        if let objc = meta["objectiveCexceptionReason"] as? [String: Any] {
            // The exception's name and class only; its message can carry values and stays in the saved file.
            let name = [text(objc["exceptionType"]), text(objc["className"])].compactMap { $0 }.joined(separator: " ")
            if !name.isEmpty { parts.append("objc \(name)") }
        }

        if let stack = frameText(from: diagnostic["callStackTree"], appBinaries: appBinaries) {
            parts.append(stack)
        }
        return parts.joined(separator: "; ")
    }

    /// "app" when the report names the app's own bundle, "extension <name>" for one of its extensions (the part
    /// of the identifier after the app's), nil when it names neither or nothing.
    static func processLabel(reported: String?, appBundleID: String?) -> String? {
        guard let reported, let appBundleID, !reported.isEmpty, !appBundleID.isEmpty else { return nil }
        if reported == appBundleID { return "app" }
        guard reported.hasPrefix(appBundleID + ".") else { return nil }
        let suffix = String(reported.dropFirst(appBundleID.count + 1).prefix(40))
        return suffix.isEmpty ? nil : "extension \(suffix)"
    }

    // MARK: Call stack

    private static func sampleCount(_ frame: [String: Any]) -> Double {
        guard let value = (frame["sampleCount"] as? NSNumber)?.doubleValue, value.isFinite else { return 0 }
        return value
    }

    /// The frame with the most samples; the first one when none says, or on a tie.
    private static func heaviest(_ frames: Any?) -> [String: Any]? {
        guard let list = frames as? [Any] else { return nil }
        var best: [String: Any]?
        var bestCount = -Double.infinity
        for case let frame as [String: Any] in list {
            let count = sampleCount(frame)
            if best == nil || count > bestCount {
                best = frame
                bestCount = count
            }
        }
        return best
    }

    /// The busiest path through the tree of the attributed thread (or, with none attributed, of the stack whose
    /// root has the most samples), in the order the report nests it: outermost JSON frame first. At each level the
    /// sub-frame with the most samples is followed. A loop, not recursion: a deep tree cannot overflow the stack.
    static func path(from callStackTree: Any?, appBinaries: Set<String> = []) -> [Frame] {
        guard let tree = callStackTree as? [String: Any],
              let stacks = tree["callStacks"] as? [Any] else { return [] }
        let candidates = stacks.compactMap { $0 as? [String: Any] }
        var chosen = candidates.first(where: { ($0["threadAttributed"] as? Bool) == true })
        if chosen == nil {
            var bestCount = -Double.infinity
            for candidate in candidates {
                let count = heaviest(candidate["callStackRootFrames"]).map(sampleCount) ?? -1
                if chosen == nil || count > bestCount {
                    chosen = candidate
                    bestCount = count
                }
            }
        }
        guard let stack = chosen else { return [] }

        var result: [Frame] = []
        var current = heaviest(stack["callStackRootFrames"])
        while let frame = current, result.count < maxDepth {
            let name = text(frame["binaryName"]) ?? "?"
            let offset = text(frame["offsetIntoBinaryTextSegment"]) ?? "?"
            result.append(Frame(name: name, offset: offset, isApp: appBinaries.contains(name)))
            current = heaviest(frame["subFrames"])
        }
        return result
    }

    /// The first `limit` frames of the busiest path, as "binaryName+offset", outermost JSON frame first.
    static func frames(from callStackTree: Any?, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        return path(from: callStackTree).prefix(limit).map(\.text)
    }

    /// The stack part of a Note, nil when the report has no stack.
    ///
    /// With frames from the app's own binaries on the busiest path, those come first: up to `appFrameLimit`,
    /// deepest first, then up to `systemFrameLimit` system frames. In a sampled tree (CPU, hang, disk) the report
    /// nests callers outside callees, so the deepest system frames are where the time went. A per-thread tree
    /// (crash) is a single chain whose direction is not relied on: both of its ends are kept.
    /// With no app frame: the whole path when short, otherwise its first `outerFrameLimit` frames and its deepest.
    static func frameText(from callStackTree: Any?, appBinaries: Set<String>) -> String? {
        let all = path(from: callStackTree, appBinaries: appBinaries)
        guard !all.isEmpty else { return nil }
        let separator = " > "
        let gap = "..."

        let app = all.filter(\.isApp)
        guard !app.isEmpty else {
            if all.count <= frameLimit { return "frames: " + all.map(\.text).joined(separator: separator) }
            let outer = all.prefix(outerFrameLimit).map(\.text)
            let deepest = all.suffix(frameLimit - outerFrameLimit).map(\.text)
            return "frames: " + (outer + [gap] + deepest).joined(separator: separator)
        }

        var parts = ["app (deepest first): " + app.suffix(appFrameLimit).reversed().map(\.text).joined(separator: separator)]
        let system = all.filter { !$0.isApp }
        let perThread = ((callStackTree as? [String: Any])?["callStackPerThread"] as? Bool) == true
        if system.isEmpty {
            // nothing to add
        } else if !perThread {
            let top = system.suffix(systemFrameLimit).reversed().map(\.text)
            parts.append("system (deepest first): " + top.joined(separator: separator))
        } else if system.count <= systemFrameLimit {
            parts.append("system: " + system.map(\.text).joined(separator: separator))
        } else {
            let half = systemFrameLimit / 2
            let ends = system.prefix(half).map(\.text) + [gap] + system.suffix(systemFrameLimit - half).map(\.text)
            parts.append("system (both ends): " + ends.joined(separator: separator))
        }
        return parts.joined(separator: "; ")
    }

    /// Daily app-exit counts from an `MXMetricPayload` JSON: one summary naming every abnormal exit count
    /// above zero, or nil when there were none.
    static func exitSummary(metricPayloadJSON: Data, fallbackBuild: String) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: metricPayloadJSON)) as? [String: Any],
              let exits = root["applicationExitMetrics"] as? [String: Any] else { return nil }

        var counts: [String] = []
        for (section, label) in [("foregroundExitData", "foreground"), ("backgroundExitData", "background")] {
            guard let data = exits[section] as? [String: Any] else { continue }
            for key in data.keys.sorted() {
                guard key.hasPrefix("cumulative"), key.hasSuffix("ExitCount"), !key.contains("Normal"),
                      let number = data[key] as? NSNumber else { continue }
                let value = number.doubleValue
                guard value.isFinite, value >= 1 else { continue }
                let name = key.dropFirst("cumulative".count).dropLast("ExitCount".count)
                counts.append("\(label) \(name) \(number.stringValue)")
            }
        }
        guard !counts.isEmpty else { return nil }

        let meta = root["metaData"] as? [String: Any] ?? [:]
        let build = text(meta["applicationBuildVersion"]) ?? text(root["latestApplicationVersion"]) ?? fallbackBuild
        return BaysylLaunchReport.truncate(
            "\(prefix) app exits; build \(build); " + counts.joined(separator: ", "),
            limit: BaysylLaunchReport.noteLimit
        )
    }

    /// A string or a number as short single-line text; nil for anything else.
    static func text(_ value: Any?) -> String? {
        let raw: String
        if let string = value as? String {
            raw = string
        } else if let number = value as? NSNumber {
            raw = number.stringValue
        } else {
            return nil
        }
        let flat = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? nil : String(flat.prefix(fieldLimit))
    }
}

// MARK: - Saved files

enum BaysylDiagnosticsStore {
    static let folderName = "BaysylDiagnostics"
    static let filePrefix = "diag-"
    static let keepNewest = 20

    static var folder: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// "diag-20261125-014748-0.json". Names sort by time.
    static func fileName(date: Date, index: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(filePrefix)\(formatter.string(from: date))-\(max(0, index)).json"
    }

    /// Which of `names` to delete so only the newest `keep` diagnostic files remain. Other files are left alone.
    static func namesToDelete(_ names: [String], keep: Int = keepNewest) -> [String] {
        let ours = names.filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(".json") }.sorted(by: >)
        return Array(ours.dropFirst(max(0, keep)))
    }

    /// Saves one payload and prunes old ones. Returns nil if anything went wrong.
    @discardableResult static func save(_ data: Data, date: Date = Date(), index: Int = 0, in directory: URL? = folder) -> URL? {
        guard let directory else { return nil }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(fileName(date: date, index: index))
            try data.write(to: url, options: .atomic)
            prune(in: directory)
            return url
        } catch {
            return nil
        }
    }

    static func prune(in directory: URL? = folder) {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in namesToDelete(names) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Saved diagnostic files, newest first (for "Share Logs").
    static func fileURLs(in directory: URL? = folder) -> [URL] {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names
            .filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(".json") }
            .sorted(by: >)
            .map { directory.appendingPathComponent($0) }
    }
}

// MARK: - How often one kind of note is sent

/// CPU-exception reports can arrive every few minutes for hours. Every payload is still saved to a file; the
/// Note is sent at most once per `interval`, and says how many were held back since the previous one.
struct BaysylDiagnosticNoteLimiter {
    static let interval: TimeInterval = 60 * 60
    static let lastSentKey = "bryan.diagnostics.cpuNoteLastSent"
    static let heldBackKey = "bryan.diagnostics.cpuNotesHeldBack"

    /// Pure: may a note go out now, given when the last one did?
    static func allows(lastSent: Date?, now: Date, interval: TimeInterval = interval) -> Bool {
        guard let lastSent else { return true }
        let elapsed = now.timeIntervalSince(lastSent)
        // A clock that went backwards must not block notes for good.
        return elapsed < 0 || elapsed >= interval
    }

    let defaults: UserDefaults

    /// The text to send, or nil when this one is held back. Not thread-safe on its own; the caller serialises.
    func admit(_ text: String, now: Date, limit: Int = BaysylLaunchReport.noteLimit) -> String? {
        let stored = defaults.object(forKey: Self.lastSentKey) as? Double
        let lastSent = stored.map { Date(timeIntervalSince1970: $0) }
        let heldBack = max(0, defaults.integer(forKey: Self.heldBackKey))
        guard Self.allows(lastSent: lastSent, now: now) else {
            defaults.set(heldBack + 1, forKey: Self.heldBackKey)
            return nil
        }
        defaults.set(now.timeIntervalSince1970, forKey: Self.lastSentKey)
        defaults.set(0, forKey: Self.heldBackKey)
        guard heldBack > 0 else { return text }
        let suffix = " (+\(heldBack) more since the last note, in the saved files)"
        return BaysylLaunchReport.truncate(text, limit: max(0, limit - suffix.count)) + suffix
    }
}

// MARK: - MetricKit subscriber

final class BaysylDiagnosticsSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = BaysylDiagnosticsSubscriber()

    private let lock = NSLock()
    private var registered = false

    /// Adds this object to MetricKit once. Payloads arrive later, on a background queue.
    func register() {
        lock.lock()
        let alreadyRegistered = registered
        registered = true
        lock.unlock()
        guard !alreadyRegistered else { return }
        MXMetricManager.shared.add(self)
    }

    /// Crash, hang, CPU-exception and disk-write-exception diagnostics.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let build = BaysylLaunchReport.currentBuildLabel
        let now = Date()
        for (index, payload) in payloads.enumerated() {
            let json = payload.jsonRepresentation()
            BaysylDiagnosticsStore.save(json, date: now, index: index)
            for summary in BaysylDiagnosticSummary.labelledSummaries(payloadJSON: json, fallbackBuild: build) {
                var text: String? = summary.text
                if summary.label == BaysylDiagnosticSummary.cpuLabel {
                    lock.lock()
                    text = BaysylDiagnosticNoteLimiter(defaults: .standard).admit(summary.text, now: now)
                    lock.unlock()
                }
                if let text { BaysylNoteOutbox.shared.enqueue(text, at: now) }
            }
        }
        BaysylStartup.flushOutbox()
    }

    /// Daily metrics: only the abnormal app-exit counts are reported; the payload itself is not saved.
    func didReceive(_ payloads: [MXMetricPayload]) {
        let build = BaysylLaunchReport.currentBuildLabel
        for payload in payloads {
            if let summary = BaysylDiagnosticSummary.exitSummary(
                metricPayloadJSON: payload.jsonRepresentation(),
                fallbackBuild: build
            ) {
                BaysylNoteOutbox.shared.enqueue(summary)
            }
        }
        BaysylStartup.flushOutbox()
    }
}
