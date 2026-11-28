import SwiftUI

// Screenshot aids for the simulator. Nothing in this file exists in a release build or on a device:
// `baysylDebugScreen()` is then an empty modifier and the sample brief is not compiled at all.
//
//   -BaysylSampleBrief 1          show a made-up brief instead of the stored one
//   -BaysylShowScreen recs        open "Baysyl recommends" over the app
//   -BaysylShowScreen addons      open the add-on settings sections over the app
//   -BaysylShowScreen speech      the same, scrolled to the end

#if DEBUG && targetEnvironment(simulator)
    enum BaysylDebug {
        static var arguments: [String] { ProcessInfo.processInfo.arguments }

        static var wantsSampleBrief: Bool { arguments.contains("-BaysylSampleBrief") }

        static var screen: String? {
            guard let index = arguments.firstIndex(of: "-BaysylShowScreen"), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }

        static let sampleBrief = BaysylBrief(
            updated: Date(timeIntervalSince1970: 1_795_875_600),
            headline: "SAMPLE: flat night, one low after the paddle",
            items: [
                .init(
                    title: "Sample item one",
                    percent: 75,
                    detail: "Made-up text to show how a detail line wraps on this screen."
                ),
                .init(title: "Sample item two", percent: 55, detail: "A second made-up line."),
                .init(title: "Sample item without a percent", percent: nil, detail: "")
            ],
            test: .init(title: "Sample test", predict: "Made-up prediction: peak 150 at 110 minutes."),
            today: "Sample today line."
        )
    }

    private struct BaysylDebugScreen: ViewModifier {
        let appState: AppState
        @State private var shown = BaysylDebug.screen

        func body(content: Content) -> some View {
            content.fullScreenCover(isPresented: Binding(get: { shown != nil }, set: { if !$0 { shown = nil } })) {
                NavigationStack {
                    switch shown {
                    case "recs":
                        BaysylRecsView()
                    case "speech":
                        ScrollViewReader { proxy in
                            List {
                                BaysylAddOnsSettingsSection()
                                Color.clear.frame(height: 1).id("end")
                            }
                            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                        }
                    default:
                        List { BaysylAddOnsSettingsSection() }
                    }
                }
                .environment(appState)
            }
        }
    }
#endif

extension View {
    @ViewBuilder func baysylDebugScreen(_ appState: AppState) -> some View {
        #if DEBUG && targetEnvironment(simulator)
            modifier(BaysylDebugScreen(appState: appState))
        #else
            self
        #endif
    }
}
