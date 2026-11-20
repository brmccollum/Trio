import SwiftUI

/// One report in full: title, date, kind, summary, then each section as a headed paragraph.
/// All text is shown as plain text exactly as sent (no Markdown, newlines kept).
struct StatReportDetailView: View {
    let report: AssistantReport
    /// Passed in by the list so this pushed view does not depend on the environment reaching it.
    let background: LinearGradient

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Stat.RootView.Constants.spacing) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(report.displayDate)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                        StatReportKindTag(report: report)
                    }
                    if !report.title.isEmpty {
                        Text(verbatim: report.title)
                            .font(.title3.weight(.semibold))
                    }
                    if !report.summary.isEmpty {
                        Text(verbatim: report.summary)
                            .font(.body)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                ForEach(Array(report.sections.enumerated()), id: \.offset) { _, section in
                    StatCard {
                        VStack(alignment: .leading, spacing: 8) {
                            if !section.heading.isEmpty {
                                Text(verbatim: section.heading)
                                    .font(.headline)
                            }
                            if !section.body.isEmpty {
                                Text(verbatim: section.body)
                                    .font(.body)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .textSelection(.enabled)
            .padding()
        }
        .background(background)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle(report.kindLabel)
    }
}
