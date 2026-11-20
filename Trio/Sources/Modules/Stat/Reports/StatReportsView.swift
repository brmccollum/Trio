import SwiftUI

/// The Statistics "Reports" tab: a read-only list of reports fetched from a URL typed here.
///
/// Display only. The source URL lives in UserDefaults (not in Trio's settings), and the only side
/// effects are one GET per appearance or pull to refresh and one cache file.
struct StatReportsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    @AppStorage(AssistantReportsStore.sourceURLDefaultsKey) private var sourceURL: String = ""

    @State private var draftURL: String = ""
    @State private var isSourceExpanded = false
    @State private var snapshot: AssistantReportsStore.Snapshot?
    @State private var errorMessage: String?
    @State private var isLoading = false

    private let store = AssistantReportsStore()

    private var hasSource: Bool {
        !sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Stat.RootView.Constants.spacing) {
                if hasSource {
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
            draftURL = sourceURL
            if !hasSource { isSourceExpanded = true }
            await refresh()
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
                            .disabled(draftURL.trimmingCharacters(in: .whitespacesAndNewlines) == sourceURL)
                        Spacer()
                        if hasSource {
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
        draftURL = trimmed
        guard trimmed != sourceURL else { return }
        sourceURL = trimmed
        snapshot = nil
        errorMessage = nil
        guard !trimmed.isEmpty else { return }
        Task { await refresh() }
    }

    /// One fetch for the current source. Runs the work off the main actor; never retries.
    @MainActor private func refresh() async {
        let source = sourceURL
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
        guard source == sourceURL else { return }
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
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.2)))
            .foregroundStyle(color)
    }
}
