import Foundation
import SwiftUI
import WidgetKit

struct LiveActivityTotalDailyDoseView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var additionalState: LiveActivityAttributes.ContentAdditionalState

    private var bolusFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(bolusFormatter.string(from: additionalState.tdd as NSNumber) ?? "--")
                    .fontWeight(.bold)
                    .font(.title3)
                    .foregroundStyle(LiveActivityOffworld.valueStyle(
                        context.state,
                        themed: LiveActivityOffworld.ink,
                        isStale: context.isStale
                    ))
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

                Text(String(localized: "U", comment: "Insulin unit"))
                    .font(.headline).fontWeight(.bold)
                    .foregroundStyle(LiveActivityOffworld.valueStyle(
                        context.state,
                        themed: LiveActivityOffworld.ink,
                        isStale: context.isStale
                    ))
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
            }
            Text("TDD")
                .font(.subheadline)
                .foregroundStyle(LiveActivityOffworld.labelStyle(context.state))
        }
    }
}
