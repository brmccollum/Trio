import SwiftUI
import Swinject

extension Main {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private var modalScheduler: TrioModalAlertScheduler {
            resolver.resolve(TrioAlertManager.self)!.modalScheduler
        }

        var body: some View {
            router.view(for: .home)
                .sheet(item: $state.modal) { modal in
                    NavigationView { modal.view }
                        .navigationViewStyle(StackNavigationViewStyle())
                        // Off-world accent on sheets; the Treatments (carb/bolus) sheet stays stock.
                        .offworldTint(active: modal.screen != .treatmentView)
                }
                .sheet(item: $state.secondaryModal) { wrapper in
                    wrapper.view
                }
                .trioAlerts(modalScheduler)
                .onChange(of: state.modal != nil || state.secondaryModal != nil) { _, isPresented in
                    appState.modalPresented = isPresented
                }
                .onAppear(perform: configureView)
                .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
        }
    }
}
