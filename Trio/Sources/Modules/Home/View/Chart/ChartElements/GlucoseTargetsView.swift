import Charts
import Foundation
import SwiftUI

struct GlucoseTargetsView: ChartContent {
    let targetProfiles: [TargetProfile]

    var body: some ChartContent {
        drawGlucoseTargets(for: targetProfiles)
    }

    /**
     Draws glucose target ranges on the chart

     - Returns: A ChartContent containing line marks representing target glucose ranges
     */
    private func drawGlucoseTargets(for targetProfiles: [TargetProfile]) -> some ChartContent {
        // Draw target lines for each profile
        ForEach(targetProfiles, id: \.self) { profile in
            LineMark(
                x: .value("Time", Date(timeIntervalSinceReferenceDate: profile.startTime)),
                y: .value("Target", profile.value)
            )
            .lineStyle(OffworldTheme.isEnabled ? .init(lineWidth: 0.75) : .init(lineWidth: 1))
            .foregroundStyle(
                OffworldTheme.isEnabled
                    ? AnyShapeStyle(OffworldTheme.Swatch.silver.color.opacity(0.3))
                    : AnyShapeStyle(Color.green.gradient)
            )

            LineMark(
                x: .value("Time", Date(timeIntervalSinceReferenceDate: profile.endTime)),
                y: .value("Target", profile.value)
            )
            .lineStyle(OffworldTheme.isEnabled ? .init(lineWidth: 0.75) : .init(lineWidth: 1))
            .foregroundStyle(
                OffworldTheme.isEnabled
                    ? AnyShapeStyle(OffworldTheme.Swatch.silver.color.opacity(0.3))
                    : AnyShapeStyle(Color.green.gradient)
            )
        }
    }
}
