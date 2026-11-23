import Foundation

// "Share sleep and workouts": the pure part. Reporting only.
//
// Sleep and workout samples (already read from Apple Health elsewhere) are collapsed here into one record per
// sleep period and one per workout, and turned into the text of an inert Nightscout Note. Nothing in this file
// touches HealthKit, the network, settings, the pump, the CGM or the algorithm.

/// What a sleep-analysis sample says, reduced to the three cases that matter here.
enum HealthShareSleepStage: Equatable {
    case inBed
    /// Any asleep value: unspecified, core, deep or REM.
    case asleep
    case awake
}

struct HealthShareSleepSample: Equatable {
    let start: Date
    let end: Date
    let stage: HealthShareSleepStage
}

/// One night or nap.
struct HealthShareSleepPeriod: Equatable {
    enum Source: String, Equatable {
        /// Built from asleep stages; `asleepMinutes` is time asleep.
        case asleep
        /// No asleep stage was recorded for this period; `asleepMinutes` is time in bed.
        case inBed
    }

    let start: Date
    let end: Date
    let asleepMinutes: Int
    let source: Source
}

struct HealthShareWorkout: Equatable {
    let uuid: UUID
    /// One word, letters and digits only, e.g. "Running".
    let typeName: String
    let start: Date
    let end: Date
    let distanceKm: Double?
    let activeKcal: Double?

    var minutes: Int {
        Int((max(0, end.timeIntervalSince(start)) / 60).rounded())
    }
}

/// One Note waiting to be uploaded. `key` identifies the record for dedupe and never leaves the phone.
struct HealthShareRecord: Equatable {
    let key: String
    let note: String
    let createdAt: Date
}

enum HealthShareCollapser {
    /// Rest samples closer together than this belong to the same sleep period.
    static let mergeGap: TimeInterval = 60 * 60

    /// Collapses raw sleep samples into one period per night or nap.
    ///
    /// Awake samples are ignored. The remaining samples (asleep stages and in-bed) are grouped wherever the gap
    /// between them is at most `mergeGap`. A group with any asleep stage runs from its first asleep start to its
    /// last asleep end, and its minutes are the union of the asleep intervals, so overlapping stages (or the same
    /// night written by two devices) are not counted twice. A group with only in-bed samples falls back to those.
    static func sleepPeriods(
        from samples: [HealthShareSleepSample],
        mergeGap: TimeInterval = mergeGap
    ) -> [HealthShareSleepPeriod] {
        let rest = samples
            .filter { $0.stage != .awake && $0.end > $0.start }
            .sorted { $0.start < $1.start }

        var groups: [[HealthShareSleepSample]] = []
        var groupEnd = Date.distantPast
        for sample in rest {
            if groups.isEmpty || sample.start.timeIntervalSince(groupEnd) > mergeGap {
                groups.append([sample])
                groupEnd = sample.end
            } else {
                groups[groups.count - 1].append(sample)
                groupEnd = max(groupEnd, sample.end)
            }
        }

        return groups.compactMap { group in
            let asleep = group.filter { $0.stage == .asleep }
            let used = asleep.isEmpty ? group : asleep
            guard let start = used.map(\.start).min(), let end = used.map(\.end).max() else { return nil }
            let minutes = Int((unionSeconds(used.map { ($0.start, $0.end) }) / 60).rounded())
            return HealthShareSleepPeriod(
                start: start,
                end: end,
                asleepMinutes: minutes,
                source: asleep.isEmpty ? .inBed : .asleep
            )
        }
    }

    /// Total time covered by the intervals, counting overlaps once.
    static func unionSeconds(_ intervals: [(Date, Date)]) -> TimeInterval {
        var total: TimeInterval = 0
        var current: (Date, Date)?
        for interval in intervals.sorted(by: { $0.0 < $1.0 }) where interval.1 > interval.0 {
            if let open = current, interval.0 <= open.1 {
                current = (open.0, max(open.1, interval.1))
            } else {
                if let open = current { total += open.1.timeIntervalSince(open.0) }
                current = interval
            }
        }
        if let open = current { total += open.1.timeIntervalSince(open.0) }
        return total
    }
}

/// The two note formats. Space-separated `key=value` pairs after a fixed prefix, times in UTC.
///
///     Health sleep: start=2026-01-02T06:10:00Z end=2026-01-02T13:02:00Z asleepMin=412
///     Health workout: type=Running start=2026-01-02T17:00:00Z end=2026-01-02T17:11:00Z min=11 km=1.61 kcal=118
///
/// `source=inBed` is added to a sleep note only when no asleep stage existed. `km` and `kcal` are left out
/// when Health has no value. The Mac-side parser is `scripts/health_notes.py`.
enum HealthShareNote {
    static let sleepPrefix = "Health sleep:"
    static let workoutPrefix = "Health workout:"

    enum Parsed: Equatable {
        case sleep(start: Date, end: Date, asleepMinutes: Int, source: HealthShareSleepPeriod.Source)
        case workout(type: String, start: Date, end: Date, minutes: Int, km: Double?, kcal: Int?)
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func date(fromISO text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    static func text(for period: HealthShareSleepPeriod) -> String {
        var text = "\(sleepPrefix) start=\(iso(period.start)) end=\(iso(period.end)) asleepMin=\(period.asleepMinutes)"
        if period.source == .inBed { text += " source=inBed" }
        return text
    }

    static func text(for workout: HealthShareWorkout) -> String {
        var text = "\(workoutPrefix) type=\(sanitizedType(workout.typeName)) start=\(iso(workout.start))"
            + " end=\(iso(workout.end)) min=\(workout.minutes)"
        if let km = workout.distanceKm, km > 0 {
            text += " km=" + String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), km)
        }
        if let kcal = workout.activeKcal, kcal > 0 {
            text += " kcal=\(Int(kcal.rounded()))"
        }
        return text
    }

    /// Letters and digits only, so the type can never break the `key=value` format.
    static func sanitizedType(_ name: String) -> String {
        let cleaned = String(name.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
        return cleaned.isEmpty ? "Other" : cleaned
    }

    static func parse(_ note: String) -> Parsed? {
        let isSleep = note.hasPrefix(sleepPrefix)
        guard isSleep || note.hasPrefix(workoutPrefix) else { return nil }
        let body = note.dropFirst((isSleep ? sleepPrefix : workoutPrefix).count)
        var fields: [String: String] = [:]
        for pair in body.split(separator: " ") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1])
        }
        guard let start = fields["start"].flatMap(date(fromISO:)),
              let end = fields["end"].flatMap(date(fromISO:)) else { return nil }
        if isSleep {
            guard let minutes = fields["asleepMin"].flatMap({ Int($0) }) else { return nil }
            let source = fields["source"].flatMap(HealthShareSleepPeriod.Source.init(rawValue:)) ?? .asleep
            return .sleep(start: start, end: end, asleepMinutes: minutes, source: source)
        }
        guard let type = fields["type"], let minutes = fields["min"].flatMap({ Int($0) }) else { return nil }
        return .workout(
            type: type,
            start: start,
            end: end,
            minutes: minutes,
            km: fields["km"].flatMap { Double($0) },
            kcal: fields["kcal"].flatMap { Int($0) }
        )
    }
}

extension HealthShareRecord {
    /// The key changes if a later sync changes the period, so a corrected night is sent again; the Mac-side
    /// table keeps one row per overlapping period, newest wins.
    init(_ period: HealthShareSleepPeriod) {
        self.init(
            key: "sleep:\(Int(period.start.timeIntervalSince1970)):\(Int(period.end.timeIntervalSince1970)):\(period.asleepMinutes)",
            note: HealthShareNote.text(for: period),
            createdAt: period.end
        )
    }

    init(_ workout: HealthShareWorkout) {
        self.init(
            key: "workout:\(workout.uuid.uuidString)",
            note: HealthShareNote.text(for: workout),
            createdAt: workout.end
        )
    }
}
