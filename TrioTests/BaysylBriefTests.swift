import Foundation
import Testing

@testable import Trio

/// Tests for the display-only Baysyl brief: defensive decoding, the read policy and the watch payload.
@Suite("Baysyl brief tests") struct BaysylBriefTests {
    private func decode(_ json: String) -> Result<BaysylBrief, BaysylBriefDecodeError> {
        BaysylBriefDecoder.decode(Data(json.utf8))
    }

    private let good = """
    {"v":1,"updated":"2026-11-28T14:20:00Z","headline":"Flat night, one low after the paddle",
     "items":[{"title":"High temp target before a paddle","percent":75,"detail":"Four lows in five days."},
              {"title":"Afternoon ratio","percent":null,"detail":"Watching."}],
     "test":{"title":"No-bolus Sludge","predict":"Peak 150 at 110 min"},
     "today":"Pod hour 60 at 11:42 am","somethingNew":{"a":[1,2,3]}}
    """

    @Test("A version 1 brief decodes, unknown fields ignored") func goodBrief() throws {
        let brief = try decode(good).get()
        #expect(brief.headline == "Flat night, one low after the paddle")
        #expect(brief.items.count == 2)
        #expect(
            brief
                .items[0] == .init(title: "High temp target before a paddle", percent: 75, detail: "Four lows in five days.")
        )
        #expect(brief.items[1].percent == nil)
        #expect(brief.test == .init(title: "No-bolus Sludge", predict: "Peak 150 at 110 min"))
        #expect(brief.today == "Pod hour 60 at 11:42 am")
        #expect(brief.updated == Date(timeIntervalSince1970: 1_795_875_600))
    }

    @Test("Optional parts may be missing") func minimalBrief() throws {
        let brief = try decode(#"{"v":1,"headline":"Hello"}"#).get()
        #expect(brief.items.isEmpty)
        #expect(brief.test == nil)
        #expect(brief.today == nil)
        #expect(brief.updated == nil)
    }

    @Test("Fractional-second and unparsable times") func times() throws {
        let fractional = try decode(#"{"v":1,"headline":"x","updated":"2026-11-28T14:20:00.250Z"}"#).get()
        #expect(fractional.updated != nil)
        let bad = try decode(#"{"v":1,"headline":"x","updated":"yesterday"}"#).get()
        #expect(bad.updated == nil)
        let number = try decode(#"{"v":1,"headline":"x","updated":12345}"#).get()
        #expect(number.updated == nil)
    }

    @Test("Malformed files are refused with a reason") func malformed() {
        #expect(decode("") == .failure(.notJSON))
        #expect(decode("{\"v\":1,\"headline\":") == .failure(.notJSON))
        #expect(decode("[1,2,3]") == .failure(.wrongShape))
        #expect(decode(#"{"headline":"no version"}"#) == .failure(.unsupportedVersion))
        #expect(decode(#"{"v":2,"headline":"newer"}"#) == .failure(.unsupportedVersion))
        #expect(decode(#"{"v":"1","headline":"text version"}"#) == .failure(.unsupportedVersion))
        #expect(decode(#"{"v":true,"headline":"bool version"}"#) == .failure(.unsupportedVersion))
        #expect(decode(#"{"v":1}"#) == .failure(.noHeadline))
        #expect(decode(#"{"v":1,"headline":42}"#) == .failure(.noHeadline))
        #expect(decode(#"{"v":1,"headline":"   "}"#) == .failure(.noHeadline))
    }

    @Test("Fields of the wrong type are treated as absent, not fatal") func wrongTypes() throws {
        let brief = try decode("""
        {"v":1,"headline":"ok","items":[7,"text",{"detail":"no title"},{"title":"kept","percent":"80","detail":9},
         {"title":"bool percent","percent":true},{"title":"too big","percent":140},{"title":"fraction","percent":64.6}],
         "test":"not an object","today":["a"]}
        """).get()
        #expect(brief.items.map(\.title) == ["kept", "bool percent", "too big", "fraction"])
        #expect(brief.items.map(\.percent) == [nil, nil, nil, 65])
        #expect(brief.items[0].detail == "")
        #expect(brief.test == nil)
        #expect(brief.today == nil)

        let itemsNotArray = try decode(#"{"v":1,"headline":"ok","items":{"title":"x"}}"#).get()
        #expect(itemsNotArray.items.isEmpty)
        let testWithoutTitle = try decode(#"{"v":1,"headline":"ok","test":{"predict":"p"}}"#).get()
        #expect(testWithoutTitle.test == nil)
    }

    @Test("Oversized content is capped: 300 characters a string, 6 items") func oversized() throws {
        let long = String(repeating: "a", count: 1000)
        let items = (1 ... 20).map { #"{"title":"item \#($0) \#(long)","percent":50,"detail":"\#(long)"}"# }
            .joined(separator: ",")
        let brief = try decode(
            #"{"v":1,"headline":"\#(long)","items":[\#(items)],"test":{"title":"\#(long)","predict":"\#(long)"},"today":"\#(long)"}"#
        ).get()
        #expect(brief.headline.count == 300)
        #expect(brief.headline.hasSuffix("…"))
        #expect(brief.items.count == 6)
        #expect(brief.items.allSatisfy { $0.title.count == 300 && $0.detail.count == 300 })
        #expect(brief.items.first?.title.hasPrefix("item 1 ") == true)
        #expect(brief.test?.title.count == 300)
        #expect(brief.test?.predict.count == 300)
        #expect(brief.today?.count == 300)
    }

    @Test("A file over the size limit is not parsed at all") func tooLarge() {
        let padding = String(repeating: " ", count: BaysylBriefDecoder.maxBytes)
        #expect(decode(#"{"v":1,"headline":"x"}"# + padding) == .failure(.tooLarge))
    }

    @Test("Line breaks are flattened and short strings are left alone") func flattening() throws {
        let brief = try decode(#"{"v":1,"headline":"  one\ntwo\r\nthree  "}"#).get()
        #expect(brief.headline == "one two  three")
        #expect(BaysylBriefDecoder.cap("abc", limit: 3) == "abc")
        #expect(BaysylBriefDecoder.cap("abcd", limit: 3) == "ab…")
        #expect(BaysylBriefDecoder.cap("abcd", limit: 0) == "")
    }

    @Test("The stored form round-trips") func storedRoundTrip() throws {
        let brief = try decode(good).get()
        let data = try JSONEncoder().encode(brief)
        #expect(try JSONDecoder().decode(BaysylBrief.self, from: data) == brief)
    }

    @Test("The store keeps the last good brief") func store() throws {
        let name = "BaysylBriefTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let brief = try decode(good).get()

        let store = BaysylBriefStore(defaults: defaults)
        #expect(store.lastGood == nil)
        #expect(store.hasFolder == false)
        store.save(brief, readAt: Date(timeIntervalSince1970: 1000))
        #expect(store.lastGood == brief)
        // A second store over the same defaults reads it back from disk form.
        #expect(BaysylBriefStore(defaults: defaults).lastGood == brief)
        #expect(BaysylBriefStore(defaults: defaults).lastGoodReadAt == Date(timeIntervalSince1970: 1000))

        store.setFolder(bookmark: Data([1, 2, 3]), name: "Baysyl")
        #expect(store.hasFolder)
        #expect(store.folderName == "Baysyl")
    }

    // MARK: Read policy

    @Test("Reads need the switch, a finished launch and a folder") func policyGates() {
        let now = Date(timeIntervalSince1970: 10000)
        func allows(addOn: Bool = true, finished: Bool = true, folder: Bool = true) -> Bool {
            BaysylBriefReadPolicy.allowsRead(
                trigger: .foreground, addOnOn: addOn, launchFinished: finished, hasFolder: folder,
                lastAttempt: nil, now: now
            )
        }
        #expect(allows())
        #expect(!allows(addOn: false))
        #expect(!allows(finished: false))
        #expect(!allows(folder: false))
    }

    @Test("The timer reads at most every 15 minutes; the foreground at most once a minute") func policyThrottle() {
        let last = Date(timeIntervalSince1970: 10000)
        func allows(_ trigger: BaysylBriefReadPolicy.Trigger, after seconds: TimeInterval) -> Bool {
            BaysylBriefReadPolicy.allowsRead(
                trigger: trigger, addOnOn: true, launchFinished: true, hasFolder: true,
                lastAttempt: last, now: last.addingTimeInterval(seconds)
            )
        }
        #expect(!allows(.timer, after: 14 * 60 + 59))
        #expect(allows(.timer, after: 15 * 60))
        #expect(!allows(.foreground, after: 59))
        #expect(allows(.foreground, after: 60))
        #expect(allows(.user, after: 1))
        // A clock that went backwards does not block reads.
        #expect(allows(.timer, after: -500))
    }

    // MARK: Watch payload

    @Test("The watch gets at most 4 items and shorter text") func watchPayload() throws {
        let long = String(repeating: "b", count: 300)
        let brief = BaysylBrief(
            updated: Date(timeIntervalSince1970: 2000),
            headline: long,
            items: (1 ... 6).map { .init(title: "t\($0) \(long)", percent: $0 == 2 ? nil : 10 * $0, detail: long) },
            test: .init(title: "Test", predict: ""),
            today: nil
        )
        let watch = BaysylWatchBrief(brief)
        #expect(watch.headline.count == 160)
        #expect(watch.items.count == 4)
        #expect(watch.items.allSatisfy { $0.title.count == 60 && $0.detail.count == 120 })

        let dictionary = watch.dictionary
        #expect(dictionary[WatchMessageKeys.baysylBriefHeadline] as? String == watch.headline)
        let items = try #require(dictionary[WatchMessageKeys.baysylBriefItems] as? [[String: Any]])
        #expect(items.count == 4)
        #expect(items[0][WatchMessageKeys.baysylBriefItemPercent] as? Int == 10)
        #expect(items[1][WatchMessageKeys.baysylBriefItemPercent] == nil)
        #expect(dictionary[WatchMessageKeys.baysylBriefTestTitle] as? String == "Test")
        #expect(dictionary[WatchMessageKeys.baysylBriefTestPredict] == nil)
        #expect(dictionary[WatchMessageKeys.baysylBriefToday] == nil)
        #expect(dictionary[WatchMessageKeys.baysylBriefUpdated] as? TimeInterval == 2000)

        // Small enough for a watch message, and made of property-list values only.
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        #expect(data.count < 2500)
    }

    @Test("Settings line") func settingsLine() {
        typealias Section = BaysylAddOnsSettingsSection
        #expect(Section.briefStatusLine(folderName: nil, lastRead: nil, status: "") == "No folder chosen.")
        #expect(Section.briefStatusLine(folderName: "Baysyl", lastRead: nil, status: "") == "Folder: Baysyl. No brief read yet.")
        #expect(
            Section.briefStatusLine(folderName: "Baysyl", lastRead: nil, status: "No brief.json in that folder yet.")
                == "Folder: Baysyl. No brief.json in that folder yet."
        )
    }
}
