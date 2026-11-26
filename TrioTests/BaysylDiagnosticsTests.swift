import Foundation
import Testing

@testable import Trio

/// Tests for the MetricKit summaries and the saved-file bookkeeping. Pure: sample payload JSON in the shape
/// MetricKit documents, no MetricKit objects, no network.
@Suite("Baysyl diagnostics tests") struct BaysylDiagnosticsTests {
    private func frame(_ name: String, _ offset: Int, sub: String = "") -> String {
        """
        {"binaryUUID":"70B89F27-1634-3580-A695-57CDB41D7743","offsetIntoBinaryTextSegment":\(offset),
         "sampleCount":20,"binaryName":"\(name)","address":74565,"subFrames":[\(sub)]}
        """
    }

    private func nestedFrames(_ count: Int) -> String {
        var json = ""
        for index in stride(from: count - 1, through: 0, by: -1) {
            json = frame("Trio", 1000 + index, sub: json)
        }
        return json
    }

    private var crashPayload: Data {
        let other = frame("libsystem_kernel.dylib", 1)
        let attributed = frame("CoreData", 4242, sub: frame("Trio", 6_657_020, sub: frame("SwiftUICore", 77)))
        return Data("""
        {"timeStampBegin":"2026-11-25 01:46:00","timeStampEnd":"2026-11-25 01:48:00",
         "crashDiagnostics":[{"version":"1.0.0",
           "callStackTree":{"callStackPerThread":true,"callStacks":[
             {"threadAttributed":false,"callStackRootFrames":[\(other)]},
             {"threadAttributed":true,"callStackRootFrames":[\(attributed)]}]},
           "diagnosticMetaData":{"appBuildVersion":"9","appVersion":"1.0.2","regionFormat":"US",
             "exceptionType":10,"osVersion":"iPhone OS 26.1 (23B85)","deviceType":"iPhone17,1",
             "bundleIdentifier":"org.example.trio","exceptionCode":0,"signal":9,
             "terminationReason":"Namespace FRONTBOARD, Code 0x8BADF00D\\nscene-update watchdog transgression",
             "objectiveCexceptionReason":{"composedMessage":"value 123 secret","exceptionType":"NSRangeException",
               "className":"NSException","formatString":"%@","arguments":["x"]},
             "platformArchitecture":"arm64e"}}],
         "hangDiagnostics":[{"version":"1.0.0",
           "callStackTree":{"callStackPerThread":false,"callStacks":[{"callStackRootFrames":[\(frame("Trio", 55))]}]},
           "diagnosticMetaData":{"appBuildVersion":"9","appVersion":"1.0.2","hangDuration":"20 sec"}}]}
        """.utf8)
    }

    @Test("A crash and a hang in one payload give two summaries with the expected fields") func crashAndHang() {
        let summaries = BaysylDiagnosticSummary.summaries(payloadJSON: crashPayload, fallbackBuild: "fallback/0")
        #expect(summaries.count == 2)
        let expectedCrash: String = [
            "Trio diagnostic: crash; build 1.0.2 (9); exception type 10; code 0; signal 9",
            "termination Namespace FRONTBOARD, Code 0x8BADF00D scene-update watchdog transgression",
            "os iPhone OS 26.1 (23B85); objc NSRangeException NSException",
            "frames: CoreData+4242 > Trio+6657020 > SwiftUICore+77"
        ].joined(separator: "; ")
        let expectedHang = "Trio diagnostic: hang; build 1.0.2 (9); hang duration 20 sec; frames: Trio+55"
        #expect(summaries.first == expectedCrash)
        #expect(summaries.last == expectedHang)
    }

    @Test("The exception message, device and bundle identifier never reach the summary") func nothingPersonal() {
        let joined = BaysylDiagnosticSummary.summaries(payloadJSON: crashPayload, fallbackBuild: "f/0").joined()
        #expect(!joined.contains("secret"))
        #expect(!joined.contains("iPhone17,1"))
        #expect(!joined.contains("org.example.trio"))
        #expect(!joined.contains("70B89F27"))
    }

    @Test("Only the first 12 frames are listed, however deep the stack") func frameLimit() {
        let payload = Data("""
        {"crashDiagnostics":[{"callStackTree":{"callStacks":[{"threadAttributed":true,
          "callStackRootFrames":[\(nestedFrames(40))]}]},"diagnosticMetaData":{}}]}
        """.utf8)
        let summaries = BaysylDiagnosticSummary.summaries(payloadJSON: payload, fallbackBuild: "branch abc/9")
        #expect(summaries.count == 1)
        let summary = summaries.first ?? ""
        #expect(summary.hasPrefix("Trio diagnostic: crash; build branch abc/9; frames: Trio+1000 > Trio+1001"))
        #expect(summary.components(separatedBy: " > ").count == 12)
        #expect(summary.hasSuffix("Trio+1011"))
    }

    @Test("CPU and disk-write exceptions are summarised; at most three notes per payload") func otherKindsAndCap() {
        let payload = Data("""
        {"cpuExceptionDiagnostics":[{"diagnosticMetaData":{"totalCPUTime":"51 sec","totalSampledTime":"60 sec"}}],
         "diskWriteExceptionDiagnostics":[
           {"diagnosticMetaData":{"writesCaused":"1,073 MB"}},
           {"diagnosticMetaData":{"writesCaused":"2,000 MB"}},
           {"diagnosticMetaData":{"writesCaused":"3,000 MB"}},
           {"diagnosticMetaData":{"writesCaused":"4,000 MB"}}]}
        """.utf8)
        let summaries = BaysylDiagnosticSummary.summaries(payloadJSON: payload, fallbackBuild: "b/9")
        #expect(summaries.count == BaysylDiagnosticSummary.maxNotesPerPayload)
        #expect(summaries.first == "Trio diagnostic: cpu exception; build b/9; cpu time 51 sec; sampled time 60 sec")
        #expect(summaries[1] == "Trio diagnostic: disk write exception; build b/9; writes 1,073 MB")
        let expectedLast = "Trio diagnostic: disk write exception; build b/9; writes 2,000 MB (+2 more in the saved file)"
        #expect(summaries.last == expectedLast)
    }

    @Test("Each note is capped, including one built from a very long field") func noteCap() {
        let long = String(repeating: "x", count: 5000)
        let diagnostics = (0 ..< 5).map { _ in
            "{\"diagnosticMetaData\":{\"terminationReason\":\"\(long)\",\"signal\":11},"
                + "\"callStackTree\":{\"callStacks\":[{\"callStackRootFrames\":[\(nestedFrames(12))]}]}}"
        }.joined(separator: ",")
        let payload = Data("{\"crashDiagnostics\":[\(diagnostics)]}".utf8)
        for limit in [1500, 200] {
            let summaries = BaysylDiagnosticSummary.summaries(payloadJSON: payload, fallbackBuild: "b/9", limit: limit)
            #expect(summaries.count == 3)
            #expect(summaries.allSatisfy { $0.count <= limit })
            #expect(summaries.allSatisfy { $0.hasPrefix("Trio diagnostic: crash") })
        }
    }

    @Test("Broken, empty or oddly shaped payloads give nothing and do not trap") func malformed() {
        let cases = [
            "",
            "not json",
            "[]",
            "{}",
            "{\"crashDiagnostics\":\"oops\"}",
            "{\"crashDiagnostics\":[1,\"two\",null]}",
            "{\"hangDiagnostics\":[]}"
        ]
        for text in cases {
            #expect(BaysylDiagnosticSummary.summaries(payloadJSON: Data(text.utf8), fallbackBuild: "b/9").isEmpty)
        }

        // Wrong types inside a diagnostic are skipped, not fatal.
        let odd = Data("""
        {"crashDiagnostics":[{"diagnosticMetaData":{"signal":{"a":1},"exceptionType":1e400,"exceptionCode":[1]},
          "callStackTree":{"callStacks":[{"callStackRootFrames":[{"binaryName":7,"subFrames":"no"}]}]}}]}
        """.utf8)
        let summaries = BaysylDiagnosticSummary.summaries(payloadJSON: odd, fallbackBuild: "b/9")
        #expect(summaries.count <= 1)
        #expect(BaysylDiagnosticSummary.frames(from: nil, limit: 12).isEmpty)
        let noStacks: [String: Any] = ["callStacks": [Any]()]
        #expect(BaysylDiagnosticSummary.frames(from: noStacks, limit: 12).isEmpty)
        let emptyFrame: [String: Any] = ["callStacks": [["callStackRootFrames": [[String: Any]()]]]]
        #expect(BaysylDiagnosticSummary.frames(from: emptyFrame, limit: 12) == ["?+?"])
    }

    @Test("App-exit metrics report only abnormal exits above zero") func exitSummary() {
        let payload = Data("""
        {"metaData":{"applicationBuildVersion":"9","osVersion":"iPhone OS 26.1"},
         "applicationExitMetrics":{
           "foregroundExitData":{"cumulativeNormalAppExitCount":7,"cumulativeAppWatchdogExitCount":3,
             "cumulativeBadAccessExitCount":0,"cumulativeMemoryResourceLimitExitCount":0},
           "backgroundExitData":{"cumulativeNormalAppExitCount":2,"cumulativeMemoryPressureExitCount":1,
             "cumulativeCPUResourceLimitExitCount":0,"cumulativeSuspendedWithLockedFileExitCount":"x"}}}
        """.utf8)
        let exits = BaysylDiagnosticSummary.exitSummary(metricPayloadJSON: payload, fallbackBuild: "b/0")
        let expectedExits = "Trio diagnostic: app exits; build 9; foreground AppWatchdog 3, background MemoryPressure 1"
        #expect(exits == expectedExits)

        let clean = Data("""
        {"applicationExitMetrics":{"foregroundExitData":{"cumulativeNormalAppExitCount":4,
          "cumulativeAppWatchdogExitCount":0},"backgroundExitData":{}}}
        """.utf8)
        #expect(BaysylDiagnosticSummary.exitSummary(metricPayloadJSON: clean, fallbackBuild: "b/0") == nil)
        #expect(BaysylDiagnosticSummary.exitSummary(metricPayloadJSON: Data("{}".utf8), fallbackBuild: "b/0") == nil)
        #expect(BaysylDiagnosticSummary.exitSummary(metricPayloadJSON: Data(), fallbackBuild: "b/0") == nil)
    }

    // MARK: Saved files

    @Test("Only the newest 20 diagnostic files are kept; other files are never chosen") func pruning() {
        let date = Date(timeIntervalSince1970: 1_764_000_000)
        let names = (0 ..< 25).map {
            BaysylDiagnosticsStore.fileName(date: date.addingTimeInterval(TimeInterval($0) * 60), index: 0)
        }
        let toDelete = BaysylDiagnosticsStore.namesToDelete(names.shuffled() + ["notes.txt", "diag-readme.md"])
        #expect(toDelete.count == 5)
        #expect(Set(toDelete) == Set(names.prefix(5)))
        #expect(BaysylDiagnosticsStore.namesToDelete(Array(names.prefix(20))).isEmpty)
        #expect(BaysylDiagnosticsStore.namesToDelete([]).isEmpty)
    }

    @Test("Saving writes the payload, lists newest first and prunes on disk") func savingAndListing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BaysylDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(BaysylDiagnosticsStore.fileURLs(in: directory).isEmpty)
        #expect(BaysylDiagnosticsStore.save(Data("x".utf8), in: nil) == nil)

        let start = Date(timeIntervalSince1970: 1_764_000_000)
        for index in 0 ..< 23 {
            let url = BaysylDiagnosticsStore.save(
                Data("{\"n\":\(index)}".utf8),
                date: start.addingTimeInterval(TimeInterval(index)),
                index: 0,
                in: directory
            )
            #expect(url != nil)
        }
        let urls = BaysylDiagnosticsStore.fileURLs(in: directory)
        #expect(urls.count == BaysylDiagnosticsStore.keepNewest)
        let newest = try #require(urls.first)
        #expect(try String(contentsOf: newest, encoding: .utf8) == "{\"n\":22}")
        #expect(newest.lastPathComponent == "diag-20251124-160022-0.json")
    }
}
