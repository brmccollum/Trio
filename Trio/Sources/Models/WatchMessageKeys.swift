enum WatchMessageKeys {
    // Request/Response Keys
    static let date = "date"
    static let units = "units"
    static let requestWatchUpdate = "requestWatchUpdate"
    static let watchState = "watchState"
    static let acknowledged = "acknowledged"
    static let ackCode = "ackCode"
    static let message = "message"

    // Treatment Keys
    static let bolus = "bolus"
    static let carbs = "carbs"
    static let cancelBolus = "cancelBolus"
    static let bolusCanceled = "bolusCanceled"
    static let bolusProgress = "bolusProgress"
    static let activeBolusAmount = "activeBolusAmount"
    static let deliveredAmount = "deliveredAmount"
    static let bolusProgressTimestamp = "bolusProgressTimestamp"

    // Recommendation Keys
    static let requestBolusRecommendation = "requestBolusRecommendation"
    static let recommendedBolus = "recommendedBolus"

    // Override Keys
    static let cancelOverride = "cancelOverride"
    static let activateOverride = "activateOverride"

    // Temp Target Keys
    static let cancelTempTarget = "cancelTempTarget"
    static let activateTempTarget = "activateTempTarget"

    // Watch State Data Keys
    static let currentGlucose = "currentGlucose"
    static let currentGlucoseColorString = "currentGlucoseColorString"
    static let trend = "trend"
    static let delta = "delta"
    static let iob = "iob"
    static let cob = "cob"
    static let lastLoopTime = "lastLoopTime"
    static let glucoseValues = "glucoseValues"
    static let minYAxisValue = "minYAxisValue"
    static let maxYAxisValue = "maxYAxisValue"
    static let overridePresets = "overridePresets"
    static let tempTargetPresets = "tempTargetPresets"

    // Limits and Settings Keys
    static let maxBolus = "maxBolus"
    static let maxCarbs = "maxCarbs"
    static let maxFat = "maxFat"
    static let maxProtein = "maxProtein"
    static let bolusIncrement = "bolusIncrement"
    static let confirmBolusFaster = "confirmBolusFaster"

    // Notification Actions
    static let snoozeDuration = "snoozeDuration"

    // Forecast
    static let showForecastWatch = "showForecastWatch"
    static let isForecastCone = "isForecastCone"
    static let forecastData = "forecastData"
    static let forecastStartDate = "forecastStartDate"
    static let forecastConeMin = "forecastConeMin"
    static let forecastConeMax = "forecastConeMax"
    static let forecastLines = "forecastLines"

    // Appearance (display only; never read by any command path)
    static let offworldTheme = "offworldTheme"

    // Today's glucose summary for the watch stats page (display only; optional strings)
    static let todayTimeInRange = "todayTimeInRange"
    static let todayAverageGlucose = "todayAverageGlucose"
    static let todayPercentLow = "todayPercentLow"
    static let todayHighestGlucose = "todayHighestGlucose"
    static let todayLowestGlucose = "todayLowestGlucose"

    // Baysyl brief for the watch's Baysyl page (display only). `baysylBrief` holds a dictionary of the keys
    // below; an empty dictionary means "no brief" and clears the page.
    static let baysylBrief = "baysylBrief"
    static let baysylBriefHeadline = "headline"
    static let baysylBriefItems = "items"
    static let baysylBriefItemTitle = "title"
    static let baysylBriefItemPercent = "percent"
    static let baysylBriefItemDetail = "detail"
    static let baysylBriefTestTitle = "testTitle"
    static let baysylBriefTestPredict = "testPredict"
    static let baysylBriefToday = "today"
    static let baysylBriefUpdated = "updated"
}
