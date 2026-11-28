import Charts
import SwiftUI
import WatchKit

struct TrioMainWatchView: View {
    @State private var state = WatchState()
    @Environment(\.scenePhase) private var scenePhase

    // misc
    @State private var currentPage: Int = 0
    @State private var rotationDegrees: Double = 0.0
    @State private var showingTempTargetSheet = false

    // view visbility
    @State private var showingTreatmentMenuSheet: Bool = false
    @State private var showingOverrideSheet: Bool = false
    // navigation flag for meal bolus combo
    @State private var continueToBolus = false
    @State private var navigationPath = NavigationPath()

    // treatments
    @State private var selectedTreatment: TreatmentOption?

    var isWatchStateDated: Bool {
        // If `lastWatchStateUpdate` is nil, treat as "dated"
        guard let lastUpdateTimestamp = state.lastWatchStateUpdate else {
            return true
        }
        let now = Date().timeIntervalSince1970
        let secondsSinceUpdate = now - lastUpdateTimestamp
        // Return true if last update older than 5 min, so 1 loop cycle
        return secondsSinceUpdate > 5 * 60
    }

    var isSessionUnreachable: Bool {
        guard let session = state.session else {
            return true // No session at all => unreachable
        }
        // Return true if not .activated OR not reachable
        return session.activationState != .activated
    }

    // Active adjustment indicator
    private func isAdjustmentActive<T>(for presets: [T], predicate: (T) -> Bool) -> Bool {
        let sortedPresets = presets.sorted { predicate($0) && !predicate($1) }
        return !sortedPresets.isEmpty && sortedPresets.first(where: predicate) != nil
    }

    private var isTempTargetActive: Bool {
        isAdjustmentActive(for: state.tempTargetPresets) { $0.isEnabled }
    }

    private var isOverrideActive: Bool {
        isAdjustmentActive(for: state.overridePresets) { $0.isEnabled }
    }

    // Computed so the main page follows the Off-world flag as soon as the phone sends it.
    private var trioBackgroundColor: LinearGradient {
        _ = state.offworldTheme
        return LinearGradient(
            gradient: Gradient(colors: [Color.bgDarkBlue, Color.bgDarkerDarkBlue]),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            TabView(selection: $currentPage) {
                // Page 1: Current glucose trend in "BG bobble"
                ZStack {
                    GlucoseTrendView(
                        state: state,
                        rotationDegrees: rotationDegrees,
                        isWatchStateDated: isWatchStateDated || isSessionUnreachable
                    )

                    if state.showSyncingAnimation {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                Color.primary,
                                state.offworldTheme ? WatchOffworldTheme.cyan : Color.tabBar,
                                Color.clear
                            )
                            .symbolEffect(
                                .variableColor.iterative,
                                options: .repeating,
                                value: state.showSyncingAnimation
                            )
                            .position(
                                x: 20,
                                y: (WKInterfaceDevice.current().screenBounds.height / 4) -
                                    7 // Font .body == 14, so half of default size for the SF Symbol image
                            )
                    }
                }.tag(0)

                // Page 2: Glucose chart
                GlucoseChartView(
                    state: state,
                    glucoseValues: state.glucoseValues
                )
                .tag(1)

                // Page 3: Today's glucose summary (display only)
                TodayStatsView(
                    timeInRange: state.todayTimeInRange,
                    average: state.todayAverageGlucose,
                    percentLow: state.todayPercentLow,
                    highest: state.todayHighestGlucose,
                    lowest: state.todayLowestGlucose,
                    offworldTheme: state.offworldTheme,
                    isDated: isWatchStateDated || isSessionUnreachable
                )
                .tag(2)

                // Page 4: the Baysyl brief (display only). A scroll view: the vertical-page tab view scrolls it
                // to its end with the Digital Crown before moving to another page.
                BaysylBriefWatchView(
                    brief: state.baysylBrief,
                    offworldTheme: state.offworldTheme
                )
                .tag(3)
            }
            .onAppear {
                /// Hard reset variables when main view appears
                /// Reset `bolusAmount` and `recommendedBolus` to ensure no stale / old value is set when user opens bolus input or meal combo the next time.
                state.bolusAmount = 0
                state.recommendedBolus = 0
                #if DEBUG && targetEnvironment(simulator)
                    // Screenshot aid, simulator debug builds only: `-BaysylSampleBrief 1 -BaysylStartPage 3`.
                    let arguments = ProcessInfo.processInfo.arguments
                    if arguments.contains("-BaysylSampleBrief") {
                        state.baysylBrief = WatchBaysylBrief(dictionary: [
                            WatchMessageKeys.baysylBriefHeadline: "SAMPLE: flat night, one low after the paddle",
                            WatchMessageKeys.baysylBriefToday: "Sample today line.",
                            WatchMessageKeys.baysylBriefItems: [
                                [
                                    WatchMessageKeys.baysylBriefItemTitle: "Sample item one",
                                    WatchMessageKeys.baysylBriefItemPercent: 75,
                                    WatchMessageKeys.baysylBriefItemDetail: "Made-up text to show how a detail line wraps."
                                ],
                                [
                                    WatchMessageKeys.baysylBriefItemTitle: "Sample item two",
                                    WatchMessageKeys.baysylBriefItemPercent: 55,
                                    WatchMessageKeys.baysylBriefItemDetail: "A second made-up line."
                                ]
                            ],
                            WatchMessageKeys.baysylBriefTestTitle: "Sample test",
                            WatchMessageKeys.baysylBriefTestPredict: "Made-up prediction: peak 150 at 110 minutes.",
                            WatchMessageKeys.baysylBriefUpdated: 1_795_875_600.0
                        ])
                    }
                    if let index = arguments.firstIndex(of: "-BaysylStartPage"), index + 1 < arguments.count,
                       let page = Int(arguments[index + 1]), (0 ... 3).contains(page)
                    {
                        currentPage = page
                    }
                #endif
            }
            .background(trioBackgroundColor)
            // No `digitalCrownRotation` binding on the tab view (stock Trio had one, 0 through 2): on watchOS 10
            // and later the vertical-page style turns pages with the Digital Crown by itself, and only without a
            // competing binding does it hand the crown to a page's scroll view until that page reaches its end.
            .tabViewStyle(.verticalPage)
            .onChange(of: scenePhase) { _, newScenePhase in
                // Wrist raise or reopening the app: ask the phone for a fresh display state.
                // (Handled here, not in TrioWatchApp, because this view owns the WatchState.)
                if newScenePhase == .active {
                    state.refreshWatchStateOnForeground()
                }
            }
            .onChange(of: state.trend) { _, newTrend in
                withAnimation {
                    updateRotation(for: newTrend)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    VStack {
                        Image(systemName: "syringe.fill")
                            .foregroundStyle(Color.insulin)

                        Text(isWatchStateDated || isSessionUnreachable ? "--" : state.iob ?? "--")
                            .foregroundStyle(isWatchStateDated ? Color.secondary : Color.white)
                            .watchOffworldDigits(active: state.offworldTheme)
                            .frame(alignment: .leading)
                            .minimumScaleFactor(0.5)
                    }.font(.caption2)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    VStack {
                        Image(systemName: "fork.knife")
                            .foregroundStyle(Color.orange)

                        Text(isWatchStateDated || isSessionUnreachable ? "--" : state.cob ?? "--")
                            .foregroundStyle(isWatchStateDated || isSessionUnreachable ? Color.secondary : Color.white)
                            .watchOffworldDigits(active: state.offworldTheme)
                            .frame(alignment: .trailing)
                            .minimumScaleFactor(0.5)
                    }.font(.caption2)
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        showingOverrideSheet = true
                    } label: {
                        Image(systemName: "clock.arrow.2.circlepath")
                            .foregroundStyle(Color.primary, isOverrideActive ? Color.primary : Color.purple)
                    }
                    .tint(isOverrideActive ? Color.purple : nil)
                    .disabled(isWatchStateDated || isSessionUnreachable)

                    Button {
                        showingTreatmentMenuSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(Color.bgDarkerDarkBlue)
                    }
                    .controlSize(.large)
                    .buttonStyle(WatchOSButtonStyle(deviceType: state.deviceType))
                    .disabled(isWatchStateDated || isSessionUnreachable)

                    Button {
                        showingTempTargetSheet = true
                    } label: {
                        Image(systemName: "target")
                            .foregroundStyle(isTempTargetActive ? Color.primary : Color.loopGreen.opacity(0.75))
                    }
                    .tint(isTempTargetActive ? Color.loopGreen.opacity(0.75) : nil)
                    .disabled(isWatchStateDated || isSessionUnreachable)
                }
            }
            .fullScreenCover(isPresented: $showingTreatmentMenuSheet) {
                TreatmentMenuView(deviceType: state.deviceType, selectedTreatment: $selectedTreatment) {
                    handleTreatmentSelection()
                }
                .onAppear {
                    // reset the conditional navigation flag when opening
                    continueToBolus = false
                }
            }
            .sheet(isPresented: $showingOverrideSheet) {
                OverridePresetsView(
                    state: state,
                    overridePresets: state.overridePresets
                ) {
                    showingOverrideSheet = false
                    navigationPath.append(NavigationDestinations.acknowledgmentPending)
                }
            }
            .sheet(isPresented: $showingTempTargetSheet) {
                TempTargetPresetsView(
                    state: state,
                    tempTargetPresets: state.tempTargetPresets
                ) {
                    showingTempTargetSheet = false
                    navigationPath.append(NavigationDestinations.acknowledgmentPending)
                }
            }
            .navigationDestination(for: NavigationDestinations.self) { destination in
                switch destination {
                case .acknowledgmentPending:
                    AcknowledgementPendingView(
                        navigationPath: $navigationPath,
                        state: state,
                        shouldNavigateToRoot: $state.shouldNavigateToRoot
                    )
                case .carbsInput:
                    CarbsInputView(
                        navigationPath: $navigationPath,
                        state: state,
                        continueToBolus: continueToBolus
                    )
                case .bolusInput:
                    BolusInputView(
                        navigationPath: $navigationPath,
                        state: state
                    )
                case .bolusConfirm:
                    BolusConfirmationView(
                        navigationPath: $navigationPath,
                        state: state,
                        bolusAmount: $state.bolusAmount,
                        confirmationProgress: $state.confirmationProgress
                    )
                }
            }
            .onChange(of: navigationPath) { _, newPath in
                if newPath.isEmpty {
                    // Reset conditional view navigation when returning to root view
                    continueToBolus = false
                }
            }
        }
        .ignoresSafeArea()
    }

    private func updateRotation(for trend: String?) {
        switch trend {
        case "DoubleUp",
             "SingleUp":
            rotationDegrees = -90
        case "FortyFiveUp":
            rotationDegrees = -45
        case "Flat":
            rotationDegrees = 0
        case "FortyFiveDown":
            rotationDegrees = 45
        case "DoubleDown",
             "SingleDown":
            rotationDegrees = 90
        default:
            rotationDegrees = 0
        }
    }

    private func handleTreatmentSelection() {
        showingTreatmentMenuSheet = false // Dismiss the sheet

        guard let treatment = selectedTreatment else { return }

        switch treatment {
        case .meal:
            navigationPath.append(NavigationDestinations.carbsInput)
        case .bolus:
            // Reset carbs amount when directly going to bolus input
            state.carbsAmount = 0
            navigationPath.append(NavigationDestinations.bolusInput)
        case .mealBolusCombo:
            continueToBolus = true // Explicitely set subsequent view navigation
            navigationPath.append(NavigationDestinations.carbsInput)
        }
    }
}

#Preview {
    TrioMainWatchView()
}
