import SwiftUI

/// The Statistics "Baysyl" tab: a doorway to the live Baysyl page, nothing more.
///
/// Display only. It fetches nothing and stores nothing; the one button opens the build-time link
/// in the browser. (It replaced a list fetched from a computer on the local network, now retired.)
struct StatReportsView: View {
    var liveURL: URL? = BaysylLink.url

    static let doorwayText = "Reports, test results and recommendations live on the Baysyl page."
    static let noLinkText = "This build has no Baysyl link, so there is nothing to open here."

    var body: some View {
        ScrollView {
            VStack(spacing: Stat.RootView.Constants.spacing) {
                StatCard {
                    VStack(spacing: 14) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(OffworldTheme.statLabelStyle)
                            .accessibilityHidden(true)

                        Text(verbatim: liveURL == nil ? Self.noLinkText : Self.doorwayText)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)

                        if let liveURL {
                            BaysylOpenButton(url: liveURL)
                                .buttonStyle(.bordered)
                                .tint(OffworldTheme.resolve(.accentColor, themed: .cyan))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
            .padding()
        }
    }
}
