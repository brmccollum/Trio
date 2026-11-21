import SwiftUI

struct ChartLegendView: View {
    @Environment(AppState.self) var appState
    @Environment(\.colorScheme) var colorScheme

    var state: Home.StateModel

    @State var legendSheetDetent = PresentationDetent.large

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                Text(
                    "The main chart in Trio is made up of various elements and shapes. Find their meanings below."
                )
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.top, 50)

                List {
                    Section {
                        VStack(alignment: .leading) {
                            Text("Chart Gestures").bold().padding(.bottom, 5).textCase(.uppercase)

                            DefinitionRow(
                                term: String(localized: "Drag"),
                                definition: Text(
                                    "Pans the chart through time. Flick and let go to keep it gliding."
                                ),
                                color: Color.primary,
                                iconString: "hand.draw"
                            )

                            DefinitionRow(
                                term: String(localized: "Pinch"),
                                definition: Text(
                                    "Zooms continuously, between one hour and a full day on screen."
                                ),
                                color: Color.primary,
                                iconString: "hand.pinch"
                            )

                            DefinitionRow(
                                term: String(localized: "Double-Tap"),
                                definition: Text(
                                    "Steps through the zoom presets — 6, 12 and 24 hours — keeping the right-hand edge of the window where it is."
                                ),
                                color: Color.primary,
                                iconString: "hand.tap"
                            )

                            DefinitionRow(
                                term: String(localized: "Press and Hold"),
                                definition: VStack(alignment: .leading, spacing: 10) {
                                    Text("Rest a finger on the chart to inspect a single reading with its IOB and COB.")
                                    Text(
                                        "Keep your finger down and slide to scrub along the curve; slide to either edge and the chart pans along with you."
                                    )
                                },
                                color: Color.primary,
                                iconString: "hand.point.up.left"
                            )
                        }.listRowBackground(Color.gray.opacity(0.1))
                    }

                    Section {
                        VStack(alignment: .leading) {
                            Text("Forecasts").bold().padding(.bottom, 5).textCase(.uppercase)
                            Text(
                                "The oref algorithm determines insulin dosing based on a number of scenarios that it estimates with different types of forecasts."
                            )
                            .font(.subheadline)
                            .foregroundColor(.primary)

                            if state.forecastDisplayType == .lines {
                                legendLinesView
                            } else {
                                legendConeOfUncertaintyView
                            }
                        }.listRowBackground(Color.gray.opacity(0.1))

                        VStack(alignment: .leading) {
                            Text("Other Elements & Shapes").bold().padding(.bottom, 5).textCase(.uppercase)

                            DefinitionRow(
                                term: String(localized: "Scheduled Basal Rate"),
                                definition: VStack(alignment: .leading, spacing: 10) {
                                    Text("This dotted line represents the hourly insulin rate of your scheduled basal insulin.")
                                    Text(
                                        "To review or change your scheduled basal rates, go to Settings > Therapy > Basal Rates."
                                    )
                                    offworldNote(
                                        "Off-world theme: the scheduled rate is the faint chrome line. Basal is drawn hanging from the top of the strip, so a longer drop means a higher rate."
                                    )
                                },
                                color: OffworldTheme.resolve(Color.insulin, themed: .chrome),
                                iconString: "ellipsis"
                            )

                            DefinitionRow(
                                term: String(localized: "Temporary Basal Rate (TBR)"),
                                definition: VStack(alignment: .leading, spacing: 10) {
                                    Text(
                                        "Shows current or past TBRs, which can be set by the oref algorithm or manually."
                                    )
                                    offworldNote(
                                        "Off-world theme: delivered basal is a faint steel fill ending in a thin steel-blue line at the rate. Dimmer fill is your scheduled rate running with no temporary rate. A glowing pink bar marks a zero temp: no basal was delivered there."
                                    )
                                },
                                color: OffworldTheme.resolve(Color.insulin, themed: .steel),
                                iconString: "square"
                            )

                            DefinitionRow(
                                term: String(localized: "Pump Suspension"),
                                definition: Text("Indicates when insulin delivery was paused, i.e. pump is suspended."),
                                color: Color.loopGray.opacity(colorScheme == .dark ? 0.3 : 0.8),
                                iconString: "square.fill"
                            )

                            DefinitionRow(
                                term: String(localized: "CGM Glucose Value"),
                                definition: VStack(alignment: .leading, spacing: 10) {
                                    if state.settingsManager.settings.smoothGlucose {
                                        Text(
                                            "Displays real-time glucose readings from your CGM that were smoothed using the Savatzky-Golay filter. The displayed glucose readings may not match the actual readings from your CGM."
                                        )
                                        Text(
                                            "Depending on your user interface settings, this may be displayed in a static (red, green, orange) or dynamic (full color spectrum) coloring scheme."
                                        )
                                    } else {
                                        Text(
                                            "Displays real-time glucose readings from your CGM. Depending on your user interface settings, this may be displayed in a static (red, green, orange) or dynamic (full color spectrum) coloring scheme."
                                        )
                                    }
                                    if OffworldTheme.isEnabled,
                                       state.settingsManager.settings.glucoseColorScheme == .staticColor
                                    {
                                        // The theme changes this element's colours, so the legend says so.
                                        Text(
                                            verbatim: "Off-world theme: readings are drawn as a line that is cyan in range, amber at or above your high threshold and red at or below your low threshold. A break in the line means readings are missing for more than 11 minutes. The glucose target is the faint silver line; your high and low thresholds are the thin amber and red lines that fade toward the screen edges."
                                        )
                                    }
                                    Text(
                                        "To modify how glucose readings are displayed, go to Settings > Features > User Interface > Glucose Color Scheme."
                                    )
                                    if state.settingsManager.settings.smoothGlucose {
                                        Text(
                                            "To disable smoothing, go to Settings > Devices > Continuous Glucose Monitor > Smooth Glucose Value and toggle off the setting."
                                        )
                                    }
                                },
                                color: OffworldTheme.isEnabled && state.settingsManager.settings
                                    .glucoseColorScheme == .staticColor
                                    ? OffworldTheme.Swatch.cyan.color
                                    : Color.green,
                                iconString: state.settingsManager.settings.smoothGlucose ? "record.circle.fill" : "circle.fill"
                            )

                            DefinitionRow(
                                term: String(localized: "Manual Glucose Measurement"),
                                definition: Text("Manually entered blood glucose, such as a fingerstick test."),
                                color: Color.red,
                                iconString: "drop.fill"
                            )

                            DefinitionRow(
                                term: String(localized: "Bolus"),
                                definition: VStack(alignment: .leading, spacing: 10) {
                                    Text(
                                        "Shows an insulin dose, which can be a small automated dose (super-micro-bolus), a manually entered dose, or one given externally (e.g., a pen shot)."
                                    )
                                    offworldNote(
                                        "Off-world theme: violet triangles with a silver rim (violet is insulin everywhere on Home; cyan is glucose only). Doses you gave (manual or external) are drawn larger than automated SMBs; within each kind a bigger dose is a bigger triangle."
                                    )
                                },
                                color: OffworldTheme.resolve(Color.insulin, themed: .violet),
                                iconString: "arrowtriangle.down.fill"
                            )

                            DefinitionRow(
                                term: String(localized: "Carb Entry"),
                                definition: VStack(alignment: .leading, spacing: 10) {
                                    Text("Tracks the carbohydrates you eat, entered to guide insulin dosing.")
                                    offworldNote(
                                        "Off-world theme: a solid gold triangle, with the grams below it. A high glucose stretch is an amber line, never a triangle."
                                    )
                                },
                                color: OffworldTheme.resolve(Color.orange, themed: .carbGold),
                                iconString: "arrowtriangle.down.fill",
                                shouldRotateIcon: true
                            )

                            DefinitionRow(
                                term: String(localized: "Fat-Protein Carb Equivalent"),
                                definition: VStack(alignment: .leading, spacing: 10) {
                                    Text(
                                        "Represents carb equivalent for fat and protein, calculated using the Warsaw Method."
                                    )
                                    Text(
                                        "To enable or configure Warsaw Method application in Trio, go to Settings > Features > Meal Settings."
                                    )
                                    offworldNote(
                                        "Off-world theme: a small hollow copper ring along the bottom of the chart, unlike the solid gold of entered carbs."
                                    )
                                },
                                color: OffworldTheme.resolve(Color.brown, themed: .copper),
                                iconString: OffworldTheme.isEnabled ? "circle" : "circle.fill"
                            )

                            DefinitionRow(
                                term: String(localized: "Override"),
                                definition: Text(
                                    "Indicates when an override is or was active, temporarily changing therapy settings (e.g., basal rate, insulin sensitivity, carb ratio, target glucose, or whether Trio can dose SMBs)."
                                ),
                                color: Color.purple.opacity(0.4),
                                iconString: "button.horizontal.fill"
                            )

                            DefinitionRow(
                                term: String(localized: "Temporary Target"),
                                definition: Text(
                                    "Marks when a short-term temporary glucose target is or was active, (potentially) altering when or how much insulin is delivered."
                                ),
                                color: Color.green.opacity(0.4),
                                iconString: "button.horizontal.fill"
                            )

                            DefinitionRow(
                                term: String(localized: "Past Insulin-on-Board (IOB)"),
                                definition: Text(
                                    "Shows the IOB value calculated by the algorithm at a specific time in the past. These values are snapshots and won’t change if insulin is added or removed after the fact."
                                ),
                                color: OffworldTheme.resolve(Color.darkerBlue.opacity(0.8), themed: .violet),
                                iconString: "line.diagonal"
                            )

                            DefinitionRow(
                                term: String(localized: "Past Carbs-on-Board (COB)"),
                                definition: Text(
                                    "Shows the COB value calculated by the algorithm at a specific time in the past. These values are snapshots and won’t change if carbs are added or removed after the fact."
                                ),
                                color: OffworldTheme.resolve(Color.orange.opacity(0.8), themed: .carbGold),
                                iconString: "line.diagonal"
                            )
                        }.listRowBackground(Color.gray.opacity(0.1))
                    }
                }
                .scrollContentBackground(.hidden)
                .navigationBarTitle("Chart Legend", displayMode: .inline)
                .padding(.trailing, 10)
                .padding(.bottom, 15)

                Button {
                    state.isLegendPresented.toggle()
                } label: {
                    Text("Got it!").bold().frame(maxWidth: .infinity, minHeight: 30, alignment: .center)
                }
                .buttonStyle(.bordered)
                .padding(.top)
            }
            .padding([.horizontal, .bottom])
            .listSectionSpacing(10)
            .ignoresSafeArea(edges: .top)
            .presentationDetents(
                [.fraction(0.9), .large],
                selection: $legendSheetDetent
            )
        }
    }

    /// A line added to an entry only while the Off-world theme is on, where the theme draws that
    /// element differently from the stock description.
    @ViewBuilder private func offworldNote(_ text: String) -> some View {
        if OffworldTheme.isEnabled {
            Text(verbatim: text)
        }
    }

    var legendLinesView: some View {
        Group {
            DefinitionRow(
                term: String(localized: "IOB (Insulin on Board)"),
                definition: Text(
                    "Forecasts future glucose readings based on the amount of insulin still active in the body."
                ),
                color: OffworldTheme.isEnabled ? OffworldTheme.forecastLineColor(type: "iob") : .insulin
            )

            DefinitionRow(
                term: String(localized: "ZT (Zero-Temp)"),
                definition: Text(
                    "Forecasts the worst-case future glucose reading scenario if no carbs are absorbed and insulin delivery is stopped until glucose starts rising."
                ),
                color: OffworldTheme.isEnabled ? OffworldTheme.forecastLineColor(type: "zt") : .zt
            )

            DefinitionRow(
                term: String(localized: "COB (Carbs on Board)"),
                definition: Text(
                    "Forecasts future glucose reading changes by considering the amount of carbohydrates still being absorbed in the body."
                ),
                color: OffworldTheme.isEnabled ? OffworldTheme.forecastLineColor(type: "cob") : .loopYellow
            )

            DefinitionRow(
                term: String(localized: "UAM (Unannounced Meal)"),
                definition: Text(
                    "Forecasts future glucose levels and insulin dosing needs for unexpected meals or other causes of glucose reading increases without prior notice."
                ),
                color: OffworldTheme.isEnabled ? OffworldTheme.forecastLineColor(type: "uam") : .uam
            )
        }
    }

    var legendConeOfUncertaintyView: some View {
        DefinitionRow(
            term: String(localized: "Cone of Uncertainty"),
            definition: VStack(alignment: .leading, spacing: 10) {
                Text(
                    "For simplicity reasons, oref's various forecast curves are displayed as a \"Cone of Uncertainty\" that depicts a possible, forecasted range of future glucose fluctuation based on the current data and the algothim's result."
                )
                offworldNote(
                    "Off-world theme: the forecast range is the soft violet band, fading with distance; its upper and lower edge are the highest and lowest forecast. The wave inside it is not a prediction of swings and its colours are not a warning; it only travels between those two edges, running from cyan through magenta to orange with distance."
                )
                Text(
                    "To modify how the forecast is displayed, go to Settings > Features > User Interface > Forecast Display Type."
                )
            },
            color: OffworldTheme.isEnabled ? OffworldTheme.Swatch.violet.color.opacity(0.6) : Color.blue.opacity(0.5)
        )
    }
}
