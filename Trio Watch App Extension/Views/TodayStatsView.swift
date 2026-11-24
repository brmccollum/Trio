import SwiftUI

/// Page 3 of the main watch view: today's glucose summary (local midnight to now).
/// Display only. Every value is a string formatted by the phone; a missing value shows dashes.
struct TodayStatsView: View {
    let timeInRange: String?
    let average: String?
    let percentLow: String?
    let highest: String?
    let lowest: String?
    /// Optional Off-world appearance, same flag the other watch views follow.
    let offworldTheme: Bool
    /// Dims the numbers when the watch state is older than one loop cycle.
    let isDated: Bool

    private static let placeholder = "--"

    private var valueColor: Color {
        if isDated { return Color.secondary }
        return offworldTheme ? WatchOffworldTheme.cyan : Color.white
    }

    private var labelColor: Color {
        offworldTheme ? WatchOffworldTheme.gold : Color.secondary
    }

    /// Any time below range today is shown in red; zero and "no data" are not.
    private var percentLowColor: Color {
        guard !isDated, let percentLow, percentLow != Self.placeholder, percentLow != "0%" else {
            return valueColor
        }
        return Color.red
    }

    var body: some View {
        VStack(spacing: 4) {
            Text("Today")
                .font(.caption2)
                .textCase(.uppercase)
                .foregroundStyle(labelColor)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(timeInRange ?? Self.placeholder)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(valueColor)
                    .watchOffworldDigits(active: offworldTheme)
                    .watchOffworldGlow(WatchOffworldTheme.cyan, active: offworldTheme && !isDated)
                Text("in range")
                    .font(.caption2)
                    .foregroundStyle(labelColor)
            }

            if offworldTheme {
                Rectangle()
                    .fill(WatchOffworldTheme.brass)
                    .frame(height: 1)
            }

            Grid(horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    cell("Average", average, valueColor)
                    cell("Time low", percentLow, percentLowColor)
                }
                GridRow {
                    cell("Highest", highest, valueColor)
                    cell("Lowest", lowest, valueColor)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 10)
    }

    private func cell(_ label: LocalizedStringKey, _ value: String?, _ color: Color) -> some View {
        VStack(spacing: 0) {
            Text(value ?? Self.placeholder)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .watchOffworldDigits(active: offworldTheme)
            Text(label)
                .font(.caption2)
                .foregroundStyle(labelColor)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    TodayStatsView(
        timeInRange: "87%",
        average: "123",
        percentLow: "2%",
        highest: "201",
        lowest: "64",
        offworldTheme: true,
        isDated: false
    )
}
