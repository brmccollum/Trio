import SwiftUI

/// The Baysyl brief as the watch received it. Display only; every string was written and capped by the phone.
struct WatchBaysylBrief: Equatable {
    struct Item: Equatable {
        var title: String
        var percent: Int?
        var detail: String
    }

    var headline: String
    var items: [Item]
    var testTitle: String?
    var testPredict: String?
    var today: String?
    var updated: Date?

    /// nil for an empty or unusable dictionary (the phone sends an empty one for "no brief").
    init?(dictionary: [String: Any]) {
        guard let headline = dictionary[WatchMessageKeys.baysylBriefHeadline] as? String, !headline.isEmpty else {
            return nil
        }
        self.headline = headline
        let rawItems = dictionary[WatchMessageKeys.baysylBriefItems] as? [[String: Any]] ?? []
        items = rawItems.prefix(4).compactMap { raw in
            guard let title = raw[WatchMessageKeys.baysylBriefItemTitle] as? String else { return nil }
            return Item(
                title: title,
                percent: raw[WatchMessageKeys.baysylBriefItemPercent] as? Int,
                detail: raw[WatchMessageKeys.baysylBriefItemDetail] as? String ?? ""
            )
        }
        testTitle = dictionary[WatchMessageKeys.baysylBriefTestTitle] as? String
        testPredict = dictionary[WatchMessageKeys.baysylBriefTestPredict] as? String
        today = dictionary[WatchMessageKeys.baysylBriefToday] as? String
        updated = (dictionary[WatchMessageKeys.baysylBriefUpdated] as? TimeInterval)
            .map { Date(timeIntervalSince1970: $0) }
    }
}

/// Page 4 of the main watch view: the Baysyl brief in a scroll view (Digital Crown or finger).
/// Display only. Nothing on this page sends a request to the phone.
struct BaysylBriefWatchView: View {
    let brief: WatchBaysylBrief?
    /// Optional Off-world appearance, same flag the other watch views follow.
    let offworldTheme: Bool

    static let emptyMessage = "No brief yet"

    private var labelColor: Color {
        offworldTheme ? WatchOffworldTheme.gold : Color.secondary
    }

    private var accentColor: Color {
        offworldTheme ? WatchOffworldTheme.cyan : Color.white
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "Baysyl")
                    .font(.caption2)
                    .textCase(.uppercase)
                    .foregroundStyle(labelColor)
                    .frame(maxWidth: .infinity, alignment: .center)

                if let brief {
                    content(brief)
                } else {
                    Text(verbatim: Self.emptyMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 10)
            // Room for the button bar, which sits over every page. The scroll view keeps clear of the
            // IOB/COB row at the top by itself.
            .padding(.top, 4)
            .padding(.bottom, 56)
        }
    }

    @ViewBuilder private func content(_ brief: WatchBaysylBrief) -> some View {
        Text(verbatim: brief.headline)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(accentColor)
            .fixedSize(horizontal: false, vertical: true)

        if let today = brief.today {
            Text(verbatim: today)
                .font(.caption2)
                .fixedSize(horizontal: false, vertical: true)
        }

        ForEach(Array(brief.items.enumerated()), id: \.offset) { _, item in
            divider
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: item.title)
                    .font(.footnote.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let percent = item.percent {
                    Text(verbatim: "\(percent)%")
                        .font(.footnote.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(accentColor)
                }
            }
            if !item.detail.isEmpty {
                Text(verbatim: item.detail)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let testTitle = brief.testTitle {
            divider
            Text(verbatim: "Test")
                .font(.caption2)
                .textCase(.uppercase)
                .foregroundStyle(labelColor)
            Text(verbatim: testTitle)
                .font(.footnote.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let predict = brief.testPredict {
                Text(verbatim: predict)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if let updated = brief.updated {
            divider
            Text(verbatim: "Updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(labelColor)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(offworldTheme ? WatchOffworldTheme.brass : Color.secondary.opacity(0.4))
            .frame(height: 1)
    }
}

#Preview {
    BaysylBriefWatchView(
        brief: WatchBaysylBrief(dictionary: [
            WatchMessageKeys.baysylBriefHeadline: "Flat night, one low after the paddle",
            WatchMessageKeys.baysylBriefItems: [
                [
                    WatchMessageKeys.baysylBriefItemTitle: "High temp target before a paddle",
                    WatchMessageKeys.baysylBriefItemPercent: 75,
                    WatchMessageKeys.baysylBriefItemDetail: "Four pre-activity lows in five days."
                ]
            ],
            WatchMessageKeys.baysylBriefTestTitle: "No-bolus Sludge",
            WatchMessageKeys.baysylBriefTestPredict: "Peak 150 at 110 min"
        ]),
        offworldTheme: true
    )
}
