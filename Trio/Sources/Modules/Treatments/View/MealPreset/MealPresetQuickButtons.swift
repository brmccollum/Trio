import CoreData
import SwiftUI

/// A card with one button per saved meal preset, shown above the Carbs / Fat / Protein card on the
/// Treatments screen. A tap adds one serving of that preset to the fields (see `quickAddPreset`),
/// exactly what the "Presets +" sheet does, without opening the sheet. Renders nothing when there
/// are no presets.
struct MealPresetQuickButtons: View {
    @Bindable var state: Treatments.StateModel

    // Same fetch and order as the "Saved Food" picker in MealPresetView.
    @FetchRequest(
        entity: MealPresetStored.entity(),
        sortDescriptors: MealPresetQuickAdd.sortDescriptors
    ) private var presets: FetchedResults<MealPresetStored>

    private enum Config {
        static let iconSize: CGFloat = 44
        static let buttonWidth: CGFloat = 64
    }

    var body: some View {
        if !presets.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(presets, id: \.objectID) { preset in
                            button(for: preset)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }
            .listRowBackground(Color.chart)
        }
    }

    private func button(for preset: MealPresetStored) -> some View {
        let shown = MealPresetQuickAdd.display(for: preset.dish)
        let count = MealPresetQuickAdd.count(of: MealPresetQuickAdd.key(for: preset), in: state.quickAddTaps)

        return Button {
            state.quickAddPreset(preset)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            VStack(spacing: 4) {
                icon(shown, count: count)
                Text(shown.label)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
            }
            .frame(width: Config.buttonWidth)
            .contentShape(Rectangle())
        }
        // Plain style keeps each button its own tap target inside the List row.
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Add \(preset.dish ?? "") to meal"))
        .accessibilityValue(Text(count > 0 ? "Added \(count) times" : ""))
    }

    // Future step: a photo per preset would be drawn here instead of the emoji or letter.
    // It needs somewhere to keep the image, which is a data model change, so it is not done here.
    @ViewBuilder private func icon(_ shown: MealPresetQuickAdd.Display, count: Int) -> some View {
        ZStack {
            Circle().fill(Color.blue.opacity(count > 0 ? 0.3 : 0.15))
            if count > 0 {
                Circle().strokeBorder(Color.blue, lineWidth: 1.5)
            }
            if shown.iconIsEmoji {
                Text(shown.icon).font(.title2)
            } else {
                Text(shown.icon)
                    .font(.headline)
                    .foregroundStyle(Color.blue)
            }
        }
        .frame(width: Config.iconSize, height: Config.iconSize)
        .overlay(alignment: .topTrailing) {
            // Shown from the second tap on, so an accidental double tap is visible.
            if let badge = MealPresetQuickAdd.badgeLabel(count: count) {
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.orange))
                    .offset(x: 8, y: -4)
            }
        }
    }
}
