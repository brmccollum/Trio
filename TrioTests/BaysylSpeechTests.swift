import Foundation
import Testing

@testable import Trio

/// Tests for the spoken alerts' wording and timing (pure; no audio is played).
@Suite("Baysyl speech tests") struct BaysylSpeechTests {
    private typealias Wording = BaysylSpeechWording
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ minutesAgo: Double) -> Date {
        now.addingTimeInterval(-minutesAgo * 60)
    }

    // MARK: Wording

    @Test("Low line with and without a trend") func lowLine() {
        #expect(Wording.lowLine(glucoseText: "57", trend: .falling) == "Glucose 57 and falling")
        #expect(Wording.lowLine(glucoseText: "64", trend: .rising) == "Glucose 64 and rising")
        #expect(Wording.lowLine(glucoseText: "68", trend: .steady) == "Glucose 68 and steady")
        #expect(Wording.lowLine(glucoseText: "57", trend: nil) == "Glucose 57")
    }

    @Test("Glucose is spoken in the user's units") func units() {
        #expect(Wording.glucoseText(mgdL: 57, mmol: false) == "57")
        #expect(Wording.glucoseText(mgdL: 57, mmol: true) == "3.2")
        #expect(Wording.glucoseText(mgdL: 72, mmol: true) == "4.0")
    }

    @Test("Loop line") func loopLine() {
        #expect(Wording.loopLine(minutes: 20) == "Trio has not looped for 20 minutes")
        #expect(Wording.loopLine(minutes: 41) == "Trio has not looped for 41 minutes")
    }

    @Test("Trend over the last 15 minutes") func trend() {
        #expect(Wording.trend(readings: [(at(15), 80), (at(10), 72), (at(5), 64), (at(0), 57)], now: now) == .falling)
        #expect(Wording.trend(readings: [(at(10), 55), (at(5), 58), (at(0), 62)], now: now) == .rising)
        #expect(Wording.trend(readings: [(at(10), 60), (at(5), 63), (at(0), 62)], now: now) == .steady)
        // Exactly the threshold counts; one less does not.
        #expect(Wording.trend(readings: [(at(10), 65), (at(0), 60)], now: now) == .falling)
        #expect(Wording.trend(readings: [(at(10), 64), (at(0), 60)], now: now) == .steady)
        // Order of the input does not matter.
        #expect(Wording.trend(readings: [(at(0), 57), (at(10), 72)], now: now) == .falling)
    }

    @Test("Readings older than 15 minutes do not shape the trend; one reading gives none") func trendWindow() {
        #expect(Wording.trend(readings: [(at(40), 150), (at(0), 60)], now: now) == nil)
        #expect(Wording.trend(readings: [(at(40), 150), (at(10), 58), (at(0), 60)], now: now) == .steady)
        #expect(Wording.trend(readings: [(at(0), 60)], now: now) == nil)
        #expect(Wording.trend(readings: [], now: now) == nil)
        #expect(Wording.trend(readings: [(at(10), 0), (at(0), 60)], now: now) == nil)
    }

    // MARK: Low throttle

    @Test("A low speaks at once, then at most every 5 minutes") func lowThrottle() {
        var throttle = BaysylLowSpeechThrottle()
        let result1 = throttle.wantsToSpeak(glucose: 65, readingDate: now, now: now)
        #expect(result1)
        throttle.spoke(at: now)

        let fourMinutes = now.addingTimeInterval(4 * 60 + 59)
        let result2 = throttle.wantsToSpeak(glucose: 60, readingDate: fourMinutes, now: fourMinutes)
        #expect(!result2)
        let fiveMinutes = now.addingTimeInterval(5 * 60)
        let result3 = throttle.wantsToSpeak(glucose: 58, readingDate: fiveMinutes, now: fiveMinutes)
        #expect(result3)
    }

    @Test("Asking without speaking does not use up the turn") func lowNotSpoken() {
        var throttle = BaysylLowSpeechThrottle()
        let result4 = throttle.wantsToSpeak(glucose: 65, readingDate: now, now: now)
        #expect(result4)
        // The speaker was busy: `spoke` was never called, so the next reading still wants to speak.
        let next = now.addingTimeInterval(60)
        let result5 = throttle.wantsToSpeak(glucose: 64, readingDate: next, now: next)
        #expect(result5)
    }

    @Test("Back at 70 stops it, and the next low speaks straight away") func lowRecovery() {
        var throttle = BaysylLowSpeechThrottle()
        let result6 = throttle.wantsToSpeak(glucose: 69, readingDate: now, now: now)
        #expect(result6)
        throttle.spoke(at: now)

        let one = now.addingTimeInterval(60)
        let result7 = throttle.wantsToSpeak(glucose: 70, readingDate: one, now: one)
        #expect(!result7)
        #expect(throttle.lastSpoken == nil)
        let two = now.addingTimeInterval(120)
        let result8 = throttle.wantsToSpeak(glucose: 69, readingDate: two, now: two)
        #expect(result8)
    }

    @Test("In range, stale or empty readings are not spoken") func lowIgnored() {
        var throttle = BaysylLowSpeechThrottle()
        let result9 = throttle.wantsToSpeak(glucose: 70, readingDate: now, now: now)
        #expect(!result9)
        let result10 = throttle.wantsToSpeak(glucose: 120, readingDate: now, now: now)
        #expect(!result10)
        let result11 = throttle.wantsToSpeak(glucose: 0, readingDate: now, now: now)
        #expect(!result11)
        let result12 = throttle.wantsToSpeak(glucose: 55, readingDate: at(13), now: now)
        #expect(!result12)
        let result13 = throttle.wantsToSpeak(glucose: 55, readingDate: at(11), now: now)
        #expect(result13)
        // A reading stamped well in the future is not trusted.
        let result14 = throttle.wantsToSpeak(glucose: 55, readingDate: now.addingTimeInterval(300), now: now)
        #expect(!result14)
    }

    // MARK: Loop throttle

    @Test("A stopped loop speaks at 20 minutes, then every 20") func loopThrottle() {
        var throttle = BaysylLoopSpeechThrottle()
        let lastLoop = now
        let result15 = throttle.minutesToAnnounce(lastLoop: lastLoop, now: now.addingTimeInterval(19 * 60 + 59))
        #expect(result15 == nil)

        let first = now.addingTimeInterval(20 * 60)
        let result16 = throttle.minutesToAnnounce(lastLoop: lastLoop, now: first)
        #expect(result16 == 20)
        throttle.spoke(at: first)

        let result17 = throttle.minutesToAnnounce(lastLoop: lastLoop, now: first.addingTimeInterval(60))
        #expect(result17 == nil)
        let result18 = throttle.minutesToAnnounce(lastLoop: lastLoop, now: first.addingTimeInterval(19 * 60))
        #expect(result18 == nil)
        let second = first.addingTimeInterval(20 * 60 + 30)
        let result19 = throttle.minutesToAnnounce(lastLoop: lastLoop, now: second)
        #expect(result19 == 40)
    }

    @Test("Checked once per glucose reading (every 5 minutes), it still speaks at 20, 40 and 60") func loopOnReadings() {
        var throttle = BaysylLoopSpeechThrottle()
        // Last loop 2 minutes before the first reading; readings arrive every 5 minutes for 70 minutes.
        let lastLoop = now.addingTimeInterval(-2 * 60)
        var spoken: [Int] = []
        for reading in 0 ... 14 {
            let time = now.addingTimeInterval(Double(reading) * 5 * 60)
            if let minutes = throttle.minutesToAnnounce(lastLoop: lastLoop, now: time) {
                spoken.append(minutes)
                throttle.spoke(at: time)
            }
        }
        #expect(spoken == [22, 42, 62])
    }

    @Test("A loop that comes back resets it") func loopRecovery() {
        var throttle = BaysylLoopSpeechThrottle()
        let first = now.addingTimeInterval(25 * 60)
        let result20 = throttle.minutesToAnnounce(lastLoop: now, now: first)
        #expect(result20 == 25)
        throttle.spoke(at: first)

        // Looped again one minute later.
        let newLoop = first.addingTimeInterval(60)
        let result21 = throttle.minutesToAnnounce(lastLoop: newLoop, now: newLoop.addingTimeInterval(60))
        #expect(result21 == nil)
        #expect(throttle.lastSpoken == nil)
        // The next stall speaks at its own 20 minutes, not 20 minutes after the last announcement.
        let result22 = throttle.minutesToAnnounce(lastLoop: newLoop, now: newLoop.addingTimeInterval(20 * 60))
        #expect(result22 == 20)
    }

    @Test("No loop on record, or one from long ago, says nothing") func loopNeverRan() {
        var throttle = BaysylLoopSpeechThrottle()
        let result23 = throttle.minutesToAnnounce(lastLoop: nil, now: now)
        #expect(result23 == nil)
        let result24 = throttle.minutesToAnnounce(lastLoop: .distantPast, now: now)
        #expect(result24 == nil)
        let result25 = throttle.minutesToAnnounce(lastLoop: now.addingTimeInterval(-25 * 60 * 60), now: now)
        #expect(result25 == nil)
        let result26 = throttle.minutesToAnnounce(lastLoop: now.addingTimeInterval(-23 * 60 * 60), now: now)
        #expect(result26 == 23 * 60)
        // A last loop in the future (clock change) is not a stall.
        let result27 = throttle.minutesToAnnounce(lastLoop: now.addingTimeInterval(600), now: now)
        #expect(result27 == nil)
    }

    // MARK: Audio mode

    @Test("Respect silent mode picks the ambient session") func audioMode() {
        #expect(BaysylSpeechAudio.mode(respectSilentMode: true) == .ambient)
        #expect(BaysylSpeechAudio.mode(respectSilentMode: false) == .playbackDucking)
    }

    @Test("The alarm flag reads back what was set") func alarmFlag() {
        #expect(BaysylAlarmAudio.isPlaying == false)
        BaysylAlarmAudio.set(true)
        #expect(BaysylAlarmAudio.isPlaying)
        BaysylAlarmAudio.set(false)
        #expect(BaysylAlarmAudio.isPlaying == false)
    }
}
