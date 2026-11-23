import ActivityKit
import Foundation

struct LiveActivityAttributes: ActivityAttributes {
    enum LiveActivityItem: String, Hashable, Codable, Equatable {
        case currentGlucoseLarge
        case currentGlucose
        case iob
        case cob
        case updatedLabel
        case totalDailyDose
        case empty

        static let defaultItems: [Self] = [.currentGlucoseLarge, .iob, .cob, .updatedLabel]
    }

    struct ContentState: Codable, Hashable {
        let unit: String
        let bg: String
        let direction: String?
        let change: String
        let date: Date?
        let highGlucose: Decimal
        let lowGlucose: Decimal
        let target: Decimal
        let glucoseColorScheme: String
        let useDetailedViewIOS: Bool
        let useDetailedViewWatchOS: Bool
        let detailedViewState: ContentAdditionalState

        /// true for the first state that is set on the activity
        let isInitialState: Bool

        /// Appearance only: true while the optional Off-world theme is on in the app, so the widget
        /// extension (which shares no storage with the app) can draw the same palette.
        /// Optional with a nil default so states written by a build without it still decode,
        /// and nil or false always means the stock look.
        var offworld: Bool? = nil
    }

    struct ContentAdditionalState: Codable, Hashable {
        let chart: [ChartItem]
        let rotationDegrees: Double
        let cob: Decimal
        let iob: Decimal
        let tdd: Decimal
        let isOverrideActive: Bool
        let overrideName: String
        let overrideDate: Date
        let overrideDuration: Decimal
        let overrideTarget: Decimal
        let isTempTargetActive: Bool
        let tempTargetName: String
        let tempTargetDate: Date
        let tempTargetDuration: Decimal
        let tempTargetTarget: Decimal
        let widgetItems: [LiveActivityItem]
        let minForecast: [Int]
        let maxForecast: [Int]
        let forecastLines: [ForecastLine]
        let forecastDisplayType: String
    }

    struct ChartItem: Codable, Hashable {
        let value: Decimal
        let date: Date
    }

    struct ForecastLine: Codable, Hashable {
        let type: String
        let values: [Int]
    }

    let startDate: Date
}
