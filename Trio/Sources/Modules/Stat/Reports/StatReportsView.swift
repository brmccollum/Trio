import SwiftUI

/// The Statistics "Reports" tab: a read-only list of reports fetched from a URL typed here.
///
/// Display only. The source URL lives in UserDefaults (not in Trio's settings), and the only side
/// effects are one GET per appearance or pull to refresh and one cache file.
struct StatReportsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL

    @AppStorage(AssistantReportsStore.sourceURLDefaultsKey) private var sourceURL: String = ""

    @State private var draftURL: String = ""
    @State private var isSourceExpanded = false
    @State private var snapshot: AssistantReportsStore.Snapshot?
    @State private var errorMessage: String?
    @State private var isLoading = false

    private let store = AssistantReportsStore()

    /// What is fetched: the typed source, or the build-time default when nothing is typed.
    private var effectiveSource: String {
        AssistantReportsStore.effectiveSource(stored: sourceURL)
    }

    private var hasSource: Bool {
        !effectiveSource.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Stat.RootView.Constants.spacing) {
                basalButton
                if hasSource {
                    linkButtons
                    statusLine
                    reportList
                } else {
                    ContentUnavailableView(
                        String(localized: "No Report Source"),
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Enter the address of a reports file under Source to show reports here.")
                    )
                }

                sourceCard
            }
            .padding()
        }
        .refreshable { await refresh() }
        .task {
            draftURL = effectiveSource
            if !hasSource { isSourceExpanded = true }
            await refresh()
        }
    }

    // MARK: - Open Basal

    /// Build-time link, shown whether or not the reports load. Hidden when the build set none.
    @ViewBuilder private var basalButton: some View {
        if let url = AssistantReportsStore.bundledBasalURL {
            Button {
                openURL(url)
            } label: {
                HStack {
                    Text(verbatim: "Open Basal")
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .accessibilityHint(Text("Opens in the browser"))
        }
    }

    // MARK: - Links

    /// Buttons for the payload's optional `links`. Each opens its http/https address in the browser.
    @ViewBuilder private var linkButtons: some View {
        let links = snapshot?.payload.openableLinks ?? []
        if !links.isEmpty {
            VStack(spacing: 8) {
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    Button {
                        if let destination = link.destination { openURL(destination) }
                    } label: {
                        HStack {
                            Text(link.displayTitle)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint(Text("Opens in the browser"))
                }
            }
        }
    }

    // MARK: - Status

    @ViewBuilder private var statusLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let snapshot {
                    Text("Last updated \(snapshot.fetchedAt, format: .relative(presentation: .named))")
                } else if isLoading {
                    Text("Loading reports…")
                }
                if isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            .foregroundStyle(Color.secondary)

            if let errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                    Text(
                        snapshot == nil
                            ? String(localized: "Could not load reports: \(errorMessage)")
                            : String(localized: "Could not refresh, showing saved reports: \(errorMessage)")
                    )
                    .foregroundStyle(Color.secondary)
                    Spacer(minLength: 0)
                }
                if AssistantReportsStore.isLocalNetworkSource(effectiveSource) {
                    Text(
                        verbatim: "The source is on your local network. Be on the same Wi-Fi, and allow Trio under Settings > Privacy & Security > Local Network."
                    )
                    .foregroundStyle(Color.secondary)
                }
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isLoading)
                .padding(.top, 2)
            }
        }
        .font(.footnote)
        .padding(.horizontal)
    }

    // MARK: - List

    @ViewBuilder private var reportList: some View {
        if let snapshot {
            let reports = snapshot.payload.sortedReports
            if reports.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Reports"),
                    systemImage: "doc.text",
                    description: Text("The source has no reports yet.")
                )
            } else {
                ForEach(reports) { report in
                    NavigationLink {
                        StatReportDetailView(
                            report: report,
                            background: appState.trioBackgroundColor(for: colorScheme)
                        )
                    } label: {
                        row(for: report)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if !isLoading, errorMessage != nil {
            ContentUnavailableView(
                String(localized: "No Reports"),
                systemImage: "wifi.slash",
                description: Text("Nothing is saved on this phone yet. Pull down to try again.")
            )
        }
    }

    private func row(for report: AssistantReport) -> some View {
        StatCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(report.displayDate)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                    StatReportKindTag(report: report)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                }
                if !report.title.isEmpty {
                    Text(report.title)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                }
                if !report.summary.isEmpty {
                    Text(report.summary)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Source

    private var sourceCard: some View {
        StatCard {
            DisclosureGroup(isExpanded: $isSourceExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("https://example.com/reports.json", text: $draftURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveSource)

                    HStack {
                        Button("Save", action: saveSource)
                            .disabled(draftURL.trimmingCharacters(in: .whitespacesAndNewlines) == effectiveSource)
                        Spacer()
                        if !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Clear", role: .destructive) {
                                draftURL = ""
                                saveSource()
                            }
                        }
                    }
                    .buttonStyle(.borderless)

                    Text("Reports are read from this address with a plain request. Nothing is sent from Trio.")
                        .foregroundStyle(Color.secondary)
                }
                .padding(.top, 8)
            } label: {
                Text("Source")
                    .foregroundStyle(Color.secondary)
            }
            .font(.footnote)
        }
    }

    // MARK: - Actions

    @MainActor private func saveSource() {
        let trimmed = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = effectiveSource
        // Typing the build-time default back in (or clearing the field) stores nothing.
        sourceURL = trimmed == AssistantReportsStore.effectiveSource(stored: "") ? "" : trimmed
        draftURL = effectiveSource
        guard effectiveSource != before else { return }
        snapshot = nil
        errorMessage = nil
        guard hasSource else { return }
        Task { await refresh() }
    }

    /// One fetch for the current source. Runs the work off the main actor; never retries.
    @MainActor private func refresh() async {
        let source = effectiveSource
        guard hasSource, !isLoading else { return }
        isLoading = true
        let store = store

        // Detached so that neither leaving the tab nor SwiftUI ending the pull-to-refresh task
        // cancels the request halfway and shows a spurious "cancelled" error.
        let result = await Task.detached(priority: .userInitiated) { () -> AssistantReportsStore.RefreshResult in
            await store.refresh(from: source)
        }.value

        isLoading = false
        // The source was edited while this was in flight; its result no longer applies.
        guard source == effectiveSource else { return }
        snapshot = result.snapshot ?? snapshot
        errorMessage = result.errorMessage
    }
}

/// Small coloured capsule naming the report kind.
struct StatReportKindTag: View {
    let report: AssistantReport

    private var color: Color {
        switch report.kind {
        case .night: return .indigo
        case .day: return .orange
        case .test: return .purple
        case .settings: return .blue
        case .note: return .teal
        case .other: return .gray
        }
    }

    var body: some View {
        Text(report.kindLabel)
            .offworldChipText()
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: OffworldTheme.isEnabled ? 2 : 100, style: .continuous)
                    .fill(color.opacity(0.2))
            )
            .foregroundStyle(color)
    }
}
