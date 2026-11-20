import Foundation
import Testing

@testable import Trio

/// Tests for the local read-only reporting patch (settings snapshot in the Nightscout profile upload,
/// and the bolus-option note). Pure: values in, JSON or text out. Nothing here touches the network,
/// the settings manager, the pump or Core Data.
@Suite("Read-only patch payload tests") struct ReadOnlyPatchPayloadTests {
    // MARK: - Helpers

    /// Encodes with the same encoder `NightscoutAPI.uploadProfile` uses, then parses back to a dictionary.
    private func encodeToDictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONCoding.encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private func number(_ dict: [String: Any], _ key: String) throws -> Double {
        try #require(dict[key] as? NSNumber, "missing numeric key \(key)").doubleValue
    }

    private func knownPreferences() -> Preferences {
        var preferences = Preferences()
        preferences.maxIOB = 7.5
        preferences.threshold_setting = 72
        preferences.enableSMBAlways = true
        preferences.enableUAM = true
        preferences.maxSMBBasalMinutes = 45
        preferences.maxUAMSMBBasalMinutes = 60
        preferences.smbDeliveryRatio = 0.6
        preferences.smbInterval = 4
        preferences.autosensMax = 1.3
        preferences.autosensMin = 0.8
        preferences.useNewFormula = true
        preferences.sigmoid = true
        preferences.adjustmentFactorSigmoid = 0.5
        preferences.adjustmentFactor = 0.9
        preferences.curve = .ultraRapid
        preferences.useCustomPeakTime = true
        preferences.insulinPeakTime = 55
        return preferences
    }

    private func knownAppSettings() -> TrioSettings {
        var settings = TrioSettings()
        settings.dosingMode = .closed
        settings.useFPUconversion = true
        settings.individualAdjustmentFactor = 1
        settings.delay = 45
        settings.minuteInterval = 20
        settings.fattyMeals = true
        settings.fattyMealFactor = Decimal(string: "0.5")!
        settings.sweetMeals = true
        settings.sweetMealFactor = Decimal(string: "1.05")!
        settings.overrideFactor = Decimal(string: "0.8")!
        settings.maxCarbs = 120
        settings.maxFat = 90
        settings.maxProtein = 80
        settings.insulinConcentration = 1
        settings.smoothGlucose = true
        return settings
    }

    private func knownSnapshot() -> NightscoutTrioSettingsSnapshot {
        NightscoutTrioSettingsSnapshot(
            preferences: knownPreferences(),
            pumpSettings: PumpSettings(insulinActionCurve: 7, maxBolus: 6, maxBasal: 3.5),
            appSettings: knownAppSettings(),
            appVersion: "1.0.2",
            branchAndSha: "bryan/readonly-settings-snapshot abc1234"
        )
    }

    private func profileStore(trioSettings: NightscoutTrioSettingsSnapshot?) -> NightscoutProfileStore {
        let scheduled = ScheduledNightscoutProfile(
            dia: 7,
            carbs_hr: 0,
            delay: 0,
            timezone: "America/Los_Angeles",
            target_low: [NightscoutTimevalue(time: "00:00", value: 100, timeAsSeconds: 0)],
            target_high: [NightscoutTimevalue(time: "00:00", value: 100, timeAsSeconds: 0)],
            sens: [NightscoutTimevalue(time: "00:00", value: 65, timeAsSeconds: 0)],
            basal: [NightscoutTimevalue(time: "00:00", value: 0.5, timeAsSeconds: 0)],
            carbratio: [NightscoutTimevalue(time: "00:00", value: 5.5, timeAsSeconds: 0)],
            units: "mg/dl"
        )
        return NightscoutProfileStore(
            defaultProfile: "default",
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            mills: 1_800_000_000_000,
            units: "mg/dl",
            enteredBy: "Trio",
            store: ["default": scheduled],
            bundleIdentifier: "test.bundle",
            deviceToken: "",
            isAPNSProduction: false,
            overridePresets: nil,
            teamID: "TESTTEAM",
            expirationDate: nil,
            trioSettings: trioSettings
        )
    }

    // MARK: - (a) Settings snapshot

    @Test("Snapshot has exactly the five top-level blocks") func snapshotTopLevelKeys() throws {
        let dict = try encodeToDictionary(knownSnapshot())
        #expect(Set(dict.keys) == ["preferences", "pumpSettings", "appSettings", "appVersion", "branchAndSha"])
        #expect(dict["appVersion"] as? String == "1.0.2")
        #expect(dict["branchAndSha"] as? String == "bryan/readonly-settings-snapshot abc1234")
    }

    @Test("Snapshot carries the known preference values under their oref key names") func snapshotPreferenceValues() throws {
        let dict = try encodeToDictionary(knownSnapshot())
        let prefs = try #require(dict["preferences"] as? [String: Any])

        #expect(try number(prefs, "max_iob") == 7.5)
        // Minimum safety threshold
        #expect(try number(prefs, "threshold_setting") == 72)
        #expect(prefs["enableSMB_always"] as? Bool == true)
        #expect(prefs["enableUAM"] as? Bool == true)
        #expect(prefs["enableSMB_with_COB"] as? Bool == false)
        #expect(try number(prefs, "maxSMBBasalMinutes") == 45)
        #expect(try number(prefs, "maxUAMSMBBasalMinutes") == 60)
        #expect(try number(prefs, "smb_delivery_ratio") == 0.6)
        #expect(try number(prefs, "SMBInterval") == 4)
        #expect(try number(prefs, "autosens_max") == 1.3)
        #expect(try number(prefs, "autosens_min") == 0.8)
        #expect(prefs["useNewFormula"] as? Bool == true)
        #expect(prefs["sigmoid"] as? Bool == true)
        #expect(try number(prefs, "adjustmentFactorSigmoid") == 0.5)
        #expect(try number(prefs, "adjustmentFactor") == 0.9)
        #expect(prefs["curve"] as? String == "ultra-rapid")
        #expect(prefs["useCustomPeakTime"] as? Bool == true)
        #expect(try number(prefs, "insulinPeakTime") == 55)
    }

    @Test("Snapshot carries pump limits") func snapshotPumpSettings() throws {
        let dict = try encodeToDictionary(knownSnapshot())
        let pump = try #require(dict["pumpSettings"] as? [String: Any])
        #expect(Set(pump.keys) == ["insulin_action_curve", "maxBolus", "maxBasal"])
        #expect(try number(pump, "insulin_action_curve") == 7)
        #expect(try number(pump, "maxBolus") == 6)
        #expect(try number(pump, "maxBasal") == 3.5)
    }

    /// Pins the full list of preference names the snapshot uploads. If Trio adds or renames a
    /// preference this fails, which is the prompt to update the analysis side.
    @Test("Snapshot preference key list is exactly the expected set") func snapshotPreferenceKeyList() throws {
        let dict = try encodeToDictionary(knownSnapshot())
        let prefs = try #require(dict["preferences"] as? [String: Any])
        let expected: Set<String> = [
            "max_iob", "max_daily_safety_multiplier", "current_basal_safety_multiplier",
            "autosens_max", "autosens_min", "smb_delivery_ratio", "rewind_resets_autosens",
            "high_temptarget_raises_sensitivity", "low_temptarget_lowers_sensitivity",
            "sensitivity_raises_target", "resistance_lowers_target", "adv_target_adjustments",
            "exercise_mode", "half_basal_exercise_target", "maxCOB", "maxMealAbsorptionTime",
            "wide_bg_target_range", "skip_neutral_temps", "unsuspend_if_no_temp",
            "min_5m_carbimpact", "remainingCarbsFraction", "remainingCarbsCap", "enableUAM",
            "A52_risk_enable", "enableSMB_with_COB", "enableSMB_with_temptarget",
            "enableSMB_always", "enableSMB_after_carbs", "allowSMB_with_high_temptarget",
            "maxSMBBasalMinutes", "maxUAMSMBBasalMinutes", "SMBInterval", "bolus_increment",
            "curve", "useCustomPeakTime", "insulinPeakTime", "carbsReqThreshold",
            "noisyCGMTargetMultiplier", "suspend_zeros_iob", "maxDelta_bg_threshold",
            "adjustmentFactor", "adjustmentFactorSigmoid", "sigmoid", "useNewFormula",
            "useWeightedAverage", "weightPercentage", "tddAdjBasal", "enableSMB_high_bg",
            "enableSMB_high_bg_target", "threshold_setting", "updateInterval"
        ]
        // `timestamp` is optional and omitted when nil.
        #expect(Set(prefs.keys) == expected)
    }

    @Test("Snapshot carries fat/protein, bolus calculator and dosing mode app settings") func snapshotAppSettingValues() throws {
        let dict = try encodeToDictionary(knownSnapshot())
        let app = try #require(dict["appSettings"] as? [String: Any])

        #expect(app["dosingMode"] as? String == "closed")
        // Fat/protein conversion: on/off, percentage, delay and spread interval (minutes).
        #expect(app["useFPUconversion"] as? Bool == true)
        #expect(try number(app, "individualAdjustmentFactor") == 1)
        #expect(try number(app, "delay") == 45)
        #expect(try number(app, "minuteInterval") == 20)
        // Bolus calculator: reduced (fatty meal) and super (sweet meal) bolus, and the recommended fraction.
        #expect(app["fattyMeals"] as? Bool == true)
        #expect(try number(app, "fattyMealFactor") == 0.5)
        #expect(app["sweetMeals"] as? Bool == true)
        #expect(try number(app, "sweetMealFactor") == 1.05)
        #expect(try number(app, "overrideFactor") == 0.8)
        #expect(try number(app, "maxCarbs") == 120)
        #expect(try number(app, "maxFat") == 90)
        #expect(try number(app, "maxProtein") == 80)
        #expect(try number(app, "insulinConcentration") == 1)
        #expect(app["smoothGlucose"] as? Bool == true)
        #expect(app["units"] as? String == "mg/dL")
    }

    /// Pins the full list of app setting names the snapshot uploads. If Trio adds a setting this
    /// fails, which is the prompt to check the new one is safe to upload and to update the analysis side.
    @Test("Snapshot app settings key list is exactly the expected set") func snapshotAppSettingsKeyList() throws {
        let dict = try encodeToDictionary(knownSnapshot())
        let app = try #require(dict["appSettings"] as? [String: Any])
        let expected: Set<String> = [
            "units", "dosingMode", "isUploadEnabled", "isDownloadEnabled", "useLocalGlucoseSource",
            "localGlucosePort", "debugOptions", "cgm", "cgmPluginIdentifier", "uploadGlucose",
            "uploadCGMSensorStates", "useCalendar", "displayCalendarIOBandCOB", "displayCalendarEmojis",
            "glucoseBadge", "carbsRequiredThreshold", "showCarbsRequiredBadge", "useFPUconversion",
            "individualAdjustmentFactor", "minuteInterval", "delay", "useAppleHealth", "smoothGlucose",
            "eA1cDisplayUnit", "high", "low", "glucoseColorScheme", "xGridLines", "yGridLines",
            "hideInsulinBadge", "allowDilution", "insulinConcentration", "showCobIobChart", "rulerMarks",
            "bolusDisplayThreshold", "forecastDisplayType", "maxCarbs", "maxFat", "maxProtein",
            "confirmBolusFaster", "showForecastWatch", "overrideFactor", "fattyMeals", "fattyMealFactor",
            "sweetMeals", "sweetMealFactor", "displayPresets", "confirmBolus", "enableQuickPickTreatments",
            "useLiveActivity", "lockScreenView", "smartStackView", "displayGlucoseForecasts",
            "bolusShortcut", "timeInRangeType", "homeStatsPanelFace", "requireAdjustmentsConfirmation",
            "garminWatchface", "garminDatafield", "primaryAttributeChoice", "secondaryAttributeChoice",
            "isWatchfaceDataEnabled"
        ]
        #expect(Set(app.keys) == expected)
        // Every value is a plain scalar (no nested objects or arrays hiding further data), with one
        // stock exception: BolusDisplayThreshold has a Decimal raw value, so Swift encodes it by case
        // name as an empty object, e.g. {"allUnits": {}}. Same shape Trio writes to its own settings file.
        for (key, value) in app where key != "bolusDisplayThreshold" {
            #expect(value is String || value is NSNumber, "\(key) is not a scalar")
        }
        let threshold = try #require(app["bolusDisplayThreshold"] as? [String: Any])
        #expect(Array(threshold.keys) == ["allUnits"])
        #expect((threshold["allUnits"] as? [String: Any])?.isEmpty == true)
    }

    @Test("Snapshot contains no credential-like keys") func snapshotHasNoSecrets() throws {
        let data = try JSONCoding.encoder.encode(knownSnapshot())
        let json = try #require(String(data: data, encoding: .utf8)).lowercased()
        // Covers all blocks, including appSettings.
        #expect(json.contains("\"appsettings\""))
        for word in ["secret", "token", "password", "url", "http", "apikey", "api_key", "email", "account"] {
            #expect(!json.contains(word), "snapshot JSON contains \(word)")
        }
    }

    @Test("Profile upload body nests the snapshot under trioSettings and keeps the stock fields") func profileStoreNesting() throws {
        let dict = try encodeToDictionary(profileStore(trioSettings: knownSnapshot()))
        let nested = try #require(dict["trioSettings"] as? [String: Any])
        let prefs = try #require(nested["preferences"] as? [String: Any])
        #expect(try number(prefs, "threshold_setting") == 72)
        #expect(nested["appVersion"] as? String == "1.0.2")
        let app = try #require(nested["appSettings"] as? [String: Any])
        #expect(try number(app, "individualAdjustmentFactor") == 1)

        // Stock fields are unchanged by the addition.
        #expect(dict["defaultProfile"] as? String == "default")
        #expect(dict["enteredBy"] as? String == "Trio")
        #expect(dict["store"] is [String: Any])
        #expect(dict["teamID"] as? String == "TESTTEAM")
    }

    @Test("Profile upload body without a snapshot has no trioSettings key") func profileStoreWithoutSnapshot() throws {
        let dict = try encodeToDictionary(profileStore(trioSettings: nil))
        #expect(dict["trioSettings"] == nil)
    }

    // MARK: - (c) Defaults

    @Test("Encoding does not throw for default settings and round-trips") func defaultSettingsEncode() throws {
        let snapshot = NightscoutTrioSettingsSnapshot(
            preferences: Preferences(),
            // Trio's own fallback when no pump settings file exists.
            pumpSettings: PumpSettings(insulinActionCurve: 10, maxBolus: 10, maxBasal: 2),
            appSettings: TrioSettings(),
            appVersion: "",
            branchAndSha: ""
        )
        let data = try JSONCoding.encoder.encode(snapshot)
        let decoded = try JSONCoding.decoder.decode(NightscoutTrioSettingsSnapshot.self, from: data)
        #expect(decoded.preferences == Preferences())
        #expect(decoded.pumpSettings.maxBolus == 10)
        #expect(decoded.appSettings == TrioSettings())

        let dict = try encodeToDictionary(snapshot)
        let prefs = try #require(dict["preferences"] as? [String: Any])
        #expect(try number(prefs, "threshold_setting") == 60)
        #expect(try number(prefs, "max_iob") == 0)
        let app = try #require(dict["appSettings"] as? [String: Any])
        #expect(try number(app, "individualAdjustmentFactor") == 0.5)
        #expect(app["useFPUconversion"] as? Bool == false)
        #expect(app["dosingMode"] as? String == "open")

        // And inside the full profile body.
        _ = try JSONCoding.encoder.encode(profileStore(trioSettings: snapshot))
    }

    // MARK: - (b) Bolus option note

    @Test("Super bolus note names the option, recommended and requested amounts") func superBolusNote() {
        let note = Treatments.StateModel.bolusOptionNoteText(
            useSuperBolus: true,
            sweetMealFactor: Decimal(string: "1.05")!,
            useFattyMealCorrectionFactor: false,
            fattyMealFactor: Decimal(string: "0.7")!,
            recommended: Decimal(string: "1.2")!,
            requested: Decimal(string: "1.25")!
        )
        #expect(note == "Bolus calc: option Super Bolus 105%; recommended 1.2 U; requested 1.25 U")
    }

    @Test("Reduced bolus note names the option, recommended and requested amounts") func reducedBolusNote() {
        let note = Treatments.StateModel.bolusOptionNoteText(
            useSuperBolus: false,
            sweetMealFactor: 1,
            useFattyMealCorrectionFactor: true,
            fattyMealFactor: Decimal(string: "0.7")!,
            recommended: Decimal(string: "0.85")!,
            requested: Decimal(string: "0.85")!
        )
        #expect(note == "Bolus calc: option Reduced Bolus 70%; recommended 0.85 U; requested 0.85 U")
    }

    @Test("Plain bolus note says option none, even when factors are configured") func plainBolusNote() {
        let note = Treatments.StateModel.bolusOptionNoteText(
            useSuperBolus: false,
            sweetMealFactor: Decimal(string: "1.05")!,
            useFattyMealCorrectionFactor: false,
            fattyMealFactor: Decimal(string: "0.7")!,
            recommended: 2,
            requested: Decimal(string: "1.5")!
        )
        #expect(note == "Bolus calc: option none; recommended 2 U; requested 1.5 U")
        #expect(!note.contains("Super Bolus"))
        #expect(!note.contains("Reduced Bolus"))
    }

    @Test("Both options ticked are both named") func bothOptionsNote() {
        let note = Treatments.StateModel.bolusOptionNoteText(
            useSuperBolus: true,
            sweetMealFactor: Decimal(string: "1.05")!,
            useFattyMealCorrectionFactor: true,
            fattyMealFactor: Decimal(string: "0.7")!,
            recommended: 1,
            requested: 1
        )
        #expect(note == "Bolus calc: option Super Bolus 105% + Reduced Bolus 70%; recommended 1 U; requested 1 U")
    }

    /// The call site passes `Decimal(Double(min(amount, maxBolus)))`. This checks that the
    /// Decimal -> Double -> Decimal round trip prints cleanly for ordinary bolus amounts.
    @Test(
        "Requested amount prints cleanly after the call site's Double round trip",
        arguments: ["0.05", "0.1", "0.35", "0.85", "1.2", "1.25", "2.3", "3.15", "4.7", "9.95"]
    ) func requestedAmountRoundTrip(amount: String) throws {
        let original = try #require(Decimal(string: amount))
        let roundTripped = Decimal(Double(original))
        let note = Treatments.StateModel.bolusOptionNoteText(
            useSuperBolus: false,
            sweetMealFactor: 1,
            useFattyMealCorrectionFactor: false,
            fattyMealFactor: 1,
            recommended: original,
            requested: roundTripped
        )
        #expect(note == "Bolus calc: option none; recommended \(amount) U; requested \(amount) U")
    }
}
