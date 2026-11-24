import Foundation
import WatchConnectivity

// MARK: - Send Data to Phone

extension WatchState {
    /// Sends a bolus insulin request to the paired iPhone
    /// - Parameters:
    ///   - amount: The insulin amount to be delivered
    func sendBolusRequest(_ amount: Decimal) {
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Bolus request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Sending bolus request: \(amount)U")
        }

        let message: [String: Any] = [
            WatchMessageKeys.bolus: amount
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("Error sending bolus request: \(error)")
            }
        }

        // Display pending communication animation
        showCommsAnimation = true
        Task {
            await WatchLogger.shared.log("⌚️ showCommsAnimation = true")
        }
    }

    /// Sends a carbohydrate entry request to the paired iPhone
    /// - Parameters:
    ///   - amount: The amount of carbs in grams
    ///   - date: The timestamp for the carb entry (defaults to current time)
    func sendCarbsRequest(_ amount: Int, _ date: Date = Date()) {
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Carbs request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Sending carbs request: \(amount)g at \(date)")
        }

        let message: [String: Any] = [
            WatchMessageKeys.carbs: amount,
            WatchMessageKeys.date: date.timeIntervalSince1970
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("Error sending carbs request: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
        }

        // Display pending communication animation
        showCommsAnimation = true
        Task {
            await WatchLogger.shared.log("⌚️ showCommsAnimation = true")
        }
    }

    /// Sends a request to cancel the current override preset to the paired iPhone
    func sendCancelOverrideRequest() {
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Cancel override request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Sending cancel override request")
        }

        let message: [String: Any] = [
            WatchMessageKeys.cancelOverride: true
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("⌚️ Error sending cancel override request: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
        }

        // Display pending communication animation
        showCommsAnimation = true
        Task {
            await WatchLogger.shared.log("⌚️ showCommsAnimation = true")
        }
    }

    /// Sends a request to activate an override preset to the paired iPhone
    /// - Parameter presetName: The name of the override preset to activate
    func sendActivateOverrideRequest(presetName: String) {
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Activate override request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Sending activate override request for preset: \(presetName)")
        }

        let message: [String: Any] = [
            WatchMessageKeys.activateOverride: presetName
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("⌚️ Error sending activate override request: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
        }

        // Display pending communication animation
        showCommsAnimation = true
        Task {
            await WatchLogger.shared.log("⌚️ showCommsAnimation = true")
        }
    }

    /// Sends a request to cancel the current temporary target to the paired iPhone
    func sendCancelTempTargetRequest() {
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Cancel temp target request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Sending cancel temp target request")
        }

        let message: [String: Any] = [
            WatchMessageKeys.cancelTempTarget: true
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("⌚️ Error sending cancel temp target request: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
        }

        // Display pending communication animation
        showCommsAnimation = true
        Task {
            await WatchLogger.shared.log("⌚️ showCommsAnimation = true")
        }
    }

    /// Sends a request to activate a temporary target preset to the paired iPhone
    /// - Parameter presetName: The name of the temporary target preset to activate
    func sendActivateTempTargetRequest(presetName: String) {
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Activate temp target request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Sending activate temp target request for preset: \(presetName)")
        }

        let message: [String: Any] = [
            WatchMessageKeys.activateTempTarget: presetName
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("⌚️ Error sending activate temp target request: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
        }

        // Display pending communication animation
        showCommsAnimation = true
        Task {
            await WatchLogger.shared.log("⌚️ showCommsAnimation = true")
        }
    }

    /// Sends a request to calculate a bolus recommendation based on the current carbs amount
    func requestBolusRecommendation() {
        guard let session = session, session.isReachable else {
            Task {
                await WatchLogger.shared.log("⌚️ Bolus recommendation request aborted: session unreachable")
            }
            return
        }

        Task {
            await WatchLogger.shared.log("⌚️ Requesting bolus recommendation for carbs: \(carbsAmount)")
        }

        // Show a progress indicator until the phone replies. This keeps the user from
        // tapping the (0 U) "Log Carbs" button before the recommendation has landed.
        DispatchQueue.main.async {
            self.showBolusCalculationProgress = true
        }

        // The phone drops the reply silently if its session is unreachable at reply
        // time, so there is no guaranteed response to clear the flag. Fall back to a
        // timeout that reveals the normal UI.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if self.showBolusCalculationProgress {
                self.showBolusCalculationProgress = false
            }
        }

        let message: [String: Any] = [
            WatchMessageKeys.requestBolusRecommendation: true,
            WatchMessageKeys.carbs: carbsAmount
        ]

        session.sendMessage(message, replyHandler: nil) { error in
            Task {
                await WatchLogger.shared.log("Error requesting bolus recommendation: \(error)")
                await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                await WatchLogger.shared.persistLogsLocally()
            }
            DispatchQueue.main.async {
                self.showBolusCalculationProgress = false
            }
        }
    }

    /// How often the display-state request is tried, and how long to wait for an answer each time.
    private static let watchStateRequestMaxAttempts = 3
    private static let watchStateRequestRetryDelay: TimeInterval = 4

    /// Asks the phone for a fresh display state. Display only: nothing here sends a treatment.
    /// If no new state has arrived after a few seconds it asks again, a bounded number of times,
    /// then clears the syncing indicator so it cannot stay on forever.
    func requestWatchStateUpdate() {
        watchStateRequestToken += 1
        sendWatchStateRequest(attempt: 1, token: watchStateRequestToken, lastUpdateAtStart: lastWatchStateUpdate)
    }

    private func sendWatchStateRequest(attempt: Int, token: Int, lastUpdateAtStart: TimeInterval?) {
        guard let session = session else {
            Task {
                await WatchLogger.shared.log("⌚️ No session available for state update")
            }
            showSyncingAnimation = false
            return
        }

        if session.activationState != .activated {
            Task {
                await WatchLogger.shared.log("⌚️ Session not activated. Activating...")
            }
            session.activate()
        } else if session.isReachable {
            Task {
                await WatchLogger.shared.log("⌚️ Requesting WatchState update from iPhone (attempt \(attempt))")
            }

            let message = [WatchMessageKeys.requestWatchUpdate: WatchMessageKeys.watchState]

            session.sendMessage(message, replyHandler: nil) { error in
                Task {
                    await WatchLogger.shared.log("⌚️ Error requesting WatchState update: \(error)")
                    await WatchLogger.shared.log("⌚️ Saving logs to disk as fallback!")
                    await WatchLogger.shared.persistLogsLocally()
                }
            }
        } else {
            Task {
                await WatchLogger.shared.log("⌚️ Phone not reachable for WatchState update (attempt \(attempt))")
            }
        }

        // Whatever happened above (sent, send error, unreachable, not activated): check back once.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.watchStateRequestRetryDelay) { [weak self] in
            guard let self else { return }
            // A newer request chain has taken over.
            guard token == self.watchStateRequestToken else { return }
            // A new state arrived; the normal update path has already cleared the indicator.
            guard self.lastWatchStateUpdate == lastUpdateAtStart else { return }

            if attempt < Self.watchStateRequestMaxAttempts {
                self.sendWatchStateRequest(attempt: attempt + 1, token: token, lastUpdateAtStart: lastUpdateAtStart)
            } else {
                Task {
                    await WatchLogger.shared.log("⌚️ No WatchState after \(attempt) requests; clearing syncing indicator")
                }
                self.showSyncingAnimation = false
            }
        }
    }
}
