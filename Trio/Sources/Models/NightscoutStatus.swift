import Foundation

struct NightscoutStatus: JSON {
    let device: String
    let openaps: OpenAPSStatus
    let pump: NSPumpStatus
    let uploader: Uploader
}

struct OpenAPSStatus: JSON {
    let iob: IOBEntry?
    let suggested: Determination?
    let enacted: Determination?
    let version: String
    let recommendedBolus: Decimal?
    /// Raw value, not the localized name: followers parse this.
    let dosingMode: String
}

struct NSPumpStatus: JSON {
    let clock: Date
    let battery: Battery?
    let reservoir: Decimal?
    let status: PumpStatus?
    let bolusIncrement: Decimal
}

struct Uploader: JSON {
    let batteryVoltage: Decimal?
    let battery: Int
    let isCharging: Bool?
}

struct NightscoutTimevalue: JSON {
    let time: String
    let value: Decimal
    let timeAsSeconds: Int?
}

struct ScheduledNightscoutProfile: JSON {
    let dia: Decimal
    let carbs_hr: Int
    let delay: Decimal
    let timezone: String
    let target_low: [NightscoutTimevalue]
    let target_high: [NightscoutTimevalue]
    let sens: [NightscoutTimevalue]
    let basal: [NightscoutTimevalue]
    let carbratio: [NightscoutTimevalue]
    let units: String
}

struct NightscoutProfileStore: JSON {
    let defaultProfile: String
    let startDate: Date
    let mills: Int
    let units: String
    let enteredBy: String
    let store: [String: ScheduledNightscoutProfile]
    let bundleIdentifier: String
    let deviceToken: String
    let isAPNSProduction: Bool
    let overridePresets: [NightscoutPresetOverride]?
    let teamID: String
    let expirationDate: Date?
    /// Custom (read-only reporting): algorithm and pump limit settings, plus the build, for outside analysis.
    /// Nightscout stores unknown profile fields untouched; nothing reads this back into Trio.
    var trioSettings: NightscoutTrioSettingsSnapshot? = nil
}

struct NightscoutTrioSettingsSnapshot: JSON {
    let preferences: Preferences
    let pumpSettings: PumpSettings
    /// App-level settings (fat/protein conversion, bolus calculator factors, dosing mode, display options).
    let appSettings: TrioSettings
    let appVersion: String
    let branchAndSha: String
}

struct NightscoutPresetOverride: JSON {
    let name: String
    let duration: Decimal?
    let percentage: Double?
    let target: Decimal?
}
