import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Views for the Baysyl brief: the folder picker used from Settings and the brief itself on "Baysyl recommends".
// Display only.

/// The system folder picker. The app is handed one folder and reads `brief.json` from it; it never writes there.
struct BaysylFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIDocumentPickerViewController, context _: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

enum BaysylBriefFormat {
    /// "Nov 28, 6:20 AM" in the phone's own style.
    static func time(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func updatedLine(_ brief: BaysylBrief) -> String {
        guard let updated = brief.updated else { return "Updated: time not given" }
        return "Updated \(time(updated))"
    }
}

/// The brief as list sections, shown above the bundled recommendations.
struct BaysylBriefSections: View {
    let brief: BaysylBrief

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: brief.headline)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: BaysylBriefFormat.updatedLine(brief))
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                if let today = brief.today {
                    Text(verbatim: today)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } header: {
            Text(verbatim: "Baysyl brief")
        }
        .listRowBackground(OffworldRowFill())

        ForEach(Array(brief.items.enumerated()), id: \.offset) { _, item in
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: item.title)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if let percent = item.percent {
                            BaysylConfidenceBadge(confidence: percent)
                        }
                    }
                    if !item.detail.isEmpty {
                        Text(verbatim: item.detail)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            .listRowBackground(OffworldRowFill())
        }

        if let test = brief.test {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "TEST")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(OffworldTheme.statLabelStyle)
                    Text(verbatim: test.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if !test.predict.isEmpty {
                        Text(verbatim: test.predict)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(OffworldRowFill())
        }
    }
}
