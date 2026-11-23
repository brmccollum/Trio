import Foundation
import SwiftUI
import WidgetKit

struct LiveActivityCOBLabelView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var additionalState: LiveActivityAttributes.ContentAdditionalState

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text("\(additionalState.cob)" as String)
                    .fontWeight(.bold)
                    .font(.title3)
                    .foregroundStyle(LiveActivityOffworld.valueStyle(
                        context.state,
                        themed: LiveActivityOffworld.carbGold,
                        isStale: context.isStale
                    ))
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

                Text(String(localized: "g", comment: "gram of carbs"))
                    .font(.headline).fontWeight(.bold)
                    .foregroundStyle(LiveActivityOffworld.valueStyle(
                        context.state,
                        themed: LiveActivityOffworld.carbGold,
                        isStale: context.isStale
                    ))
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
            }
            Text("COB")
                .font(.subheadline)
                .foregroundStyle(LiveActivityOffworld.labelStyle(context.state))
        }
    }
}
