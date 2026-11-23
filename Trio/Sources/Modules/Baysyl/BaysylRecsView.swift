import SwiftUI

/// "Baysyl recommends": a read-only list of the recommendations bundled with this build.
///
/// Display only. It shows text from `BaysylRecs.json` and offers the browser link to the live page.
/// Nothing on this screen changes a setting or reaches the pump, the CGM, the algorithm or any upload.
struct BaysylRecsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(AppState.self) private var appState

    /// Injected for previews and tests; the default reads the app bundle.
    var result: BaysylRecsLoader.LoadResult = BaysylRecsLoader.load()
    var liveURL: URL? = BaysylLink.url

    static let emptyMessage = "No recommendations bundled in this build. Open Baysyl for the live list."
    static let unreadableMessage =
        "The recommendations bundled in this build could not be read. Open Baysyl for the live list."

    var body: some View {
        List {
            switch result {
            case let .loaded(recs) where !recs.recs.isEmpty:
                header(recs)
                ForEach(recs.recs) { rec in
                    Section {
                        BaysylRecRow(rec: rec)
                    }
                    .listRowBackground(OffworldRowFill())
                }
            case .absent,
                 .loaded:
                emptyState(Self.emptyMessage)
            case .unreadable:
                emptyState(Self.unreadableMessage)
            }

            if let liveURL {
                Section {
                    BaysylOpenButton(url: liveURL)
                } footer: {
                    Text(verbatim: "This list is a snapshot from when the build was made. The live page is always newer.")
                }
                .listRowBackground(OffworldRowFill())
            }

            Section {} footer: {
                Text(verbatim: "For reading only. Nothing here changes a setting; you make every change yourself.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(OffworldHaze())
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle(Text(verbatim: "Baysyl recommends"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func header(_ recs: BaysylRecs) -> some View {
        if !recs.asOf.isEmpty || !recs.note.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    if !recs.asOf.isEmpty {
                        Text(verbatim: "As of \(recs.displayAsOf)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(OffworldTheme.statLabelStyle)
                    }
                    if !recs.note.isEmpty {
                        Text(verbatim: recs.note)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .listRowBackground(OffworldRowFill())
        }
    }

    private func emptyState(_ message: String) -> some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.largeTitle)
                    .foregroundStyle(OffworldTheme.statLabelStyle)
                    .accessibilityHidden(true)
                Text(verbatim: message)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
        .listRowBackground(OffworldRowFill())
    }
}

/// One recommendation: title and confidence badge, then the why and next lines.
struct BaysylRecRow: View {
    let rec: BaysylRecs.Rec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: rec.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let confidence = rec.confidence {
                    BaysylConfidenceBadge(confidence: confidence)
                }
            }
            if !rec.why.isEmpty {
                line(label: "Why", text: rec.why)
            }
            if !rec.next.isEmpty {
                line(label: "Next", text: rec.next)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func line(label: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: label.uppercased())
                .font(.caption.weight(.heavy))
                .foregroundStyle(OffworldTheme.statLabelStyle)
                .frame(width: 44, alignment: .leading)
            Text(verbatim: text)
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Percent confidence in a small capsule. The colour is a reading aid only: the number is always shown.
struct BaysylConfidenceBadge: View {
    let confidence: Int

    enum Level: Equatable {
        case high
        case medium
        case low
    }

    static func level(for confidence: Int) -> Level {
        if confidence >= 80 { return .high }
        if confidence >= 50 { return .medium }
        return .low
    }

    private var color: Color {
        switch Self.level(for: confidence) {
        case .high: return OffworldTheme.resolve(.green, themed: .mint)
        case .medium: return OffworldTheme.resolve(.orange, themed: .amber)
        case .low: return OffworldTheme.resolve(.gray, themed: .steel)
        }
    }

    var body: some View {
        Text(verbatim: "\(confidence)%")
            .font(.subheadline.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: OffworldTheme.isEnabled ? 3 : 100, style: .continuous)
                    .fill(color.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OffworldTheme.isEnabled ? 3 : 100, style: .continuous)
                    .strokeBorder(color.opacity(0.55), lineWidth: 1)
            )
            .accessibilityLabel(Text(verbatim: "\(confidence) percent confidence"))
    }
}

/// The "Open Baysyl" row: opens the live page in the browser.
struct BaysylOpenButton: View {
    let url: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            openURL(url)
        } label: {
            HStack {
                Text(verbatim: "Open Baysyl")
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .accessibilityHidden(true)
            }
        }
        .accessibilityHint(Text("Opens in the browser"))
    }
}
