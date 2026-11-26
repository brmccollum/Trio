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

    /// One entry per kind of diagnostic in a payload, in the order they are reported.
    private static let kinds: [(key: String, label: String)] = [
        ("crashDiagnostics", "crash"),
        ("hangDiagnostics", "hang"),
        ("cpuExceptionDiagnostics", "cpu exception"),
        ("diskWriteExceptionDiagnostics", "disk write exception")
    ]

    /// Summaries for one `MXDiagnosticPayload` JSON: at most `maxNotesPerPayload`, each at most `limit` characters.
    /// `fallbackBuild` is used when the payload does not name the build.
    static func summaries(
        payloadJSON: Data,
        fallbackBuild: String,
        limit: Int = BaysylLaunchReport.noteLimit
    ) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: payloadJSON)) as? [String: Any] else { return [] }

        var all: [String] = []
        for kind in kinds {
            guard let diagnostics = root[kind.key] as? [Any] else { continue }
            for case let diagnostic as [String: Any] in diagnostics {
                all.append(summary(of: diagnostic, label: kind.label, fallbackBuild: fallbackBuild))
            }
        }
        guard !all.isEmpty else { return [] }

        var kept = Array(all.prefix(maxNotesPerPayload))
        let dropped = all.count - kept.count
        if dropped > 0, let last = kept.popLast() {
            let suffix = " (+\(dropped) more in the saved file)"
            kept.append(BaysylLaunchReport.truncate(last, limit: max(0, limit - suffix.count)) + suffix)
        }
        return kept.map { BaysylLaunchReport.truncate($0, limit: limit) }
    }

    static func summary(of diagnostic: [String: Any], label: String, fallbackBuild: String) -> String {
        let meta = diagnostic["diagnosticMetaData"] as? [String: Any] ?? [:]
        var parts: [String] = ["\(prefix) \(label)"]

        let version = text(meta["appVersion"])
        let build = text(meta["appBuildVersion"])
        if version != nil || build != nil {
            parts.append("build \(version ?? "?") (\(build ?? "?"))")
        } else {
            parts.append("build \(fallbackBuild)")
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

        let stack = frames(from: diagnostic["callStackTree"], limit: frameLimit)
        if !stack.isEmpty {
            parts.append("frames: " + stack.joined(separator: " > "))
        }
        return parts.joined(separator: "; ")
    }

    /// The first `limit` frames of the attributed thread (or of the first thread), as "binaryName+offset",
    /// in the order the report lists them: outermost JSON frame first, then down its first sub-frame.
    static func frames(from callStackTree: Any?, limit: Int) -> [String] {
        guard limit > 0,
              let tree = callStackTree as? [String: Any],
              let stacks = tree["callStacks"] as? [Any] else { return [] }
        let candidates = stacks.compactMap { $0 as? [String: Any] }
        guard let stack = candidates.first(where: { ($0["threadAttributed"] as? Bool) == true }) ?? candidates.first
        else { return [] }

        var result: [String] = []
        var current = (stack["callStackRootFrames"] as? [Any])?.first as? [String: Any]
        // A loop, not recursion: a deep tree cannot overflow the stack.
        while let frame = current, result.count < limit {
            let name = text(frame["binaryName"]) ?? "?"
            let offset = text(frame["offsetIntoBinaryTextSegment"]) ?? "?"
            result.append("\(name)+\(offset)")
            current = (frame["subFrames"] as? [Any])?.first as? [String: Any]
        }
        return result
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
            for summary in BaysylDiagnosticSummary.summaries(payloadJSON: json, fallbackBuild: build) {
                BaysylNoteOutbox.shared.enqueue(summary, at: now)
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
