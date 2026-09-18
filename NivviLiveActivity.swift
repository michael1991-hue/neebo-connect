import Foundation
import ActivityKit

enum NivviLiveActivityBridge {
    private static var lastPush = Date.distantPast
    static var lastTitle = "Nivvi"

    static func syncShare(heartRate: String, oxygen: String, linked: Bool, status: String) {
        sync(
            title: lastTitle,
            heartRate: heartRate,
            oxygen: oxygen,
            connection: linked ? "Shared over Wi‑Fi" : status,
            signal: "Wi‑Fi",
            nurseryHint: linked ? "" : status,
            monitoring: true
        )
    }

    static func sync(title: String, heartRate: String, oxygen: String, connection: String, signal: String, nurseryHint: String, monitoring: Bool) {
        lastTitle = title
        guard #available(iOS 16.1, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = NivviActivityAttributes.ContentState(
            heartRate: heartRate,
            oxygen: oxygen,
            connection: connection,
            signal: signal,
            nurseryHint: nurseryHint
        )
        if !monitoring {
            Task { @MainActor in
                for activity in Activity<NivviActivityAttributes>.activities {
                    if #available(iOS 16.2, *) {
                        await activity.end(nil, dismissalPolicy: .immediate)
                    } else {
                        await activity.end(dismissalPolicy: .immediate)
                    }
                }
            }
            return
        }
        if let activity = Activity<NivviActivityAttributes>.activities.first {
            if Date().timeIntervalSince(lastPush) < 1 { return }
            lastPush = Date()
            Task {
                if #available(iOS 16.2, *) {
                    await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(45)))
                } else {
                    await activity.update(using: state)
                }
            }
            return
        }
        lastPush = Date()
        let attributes = NivviActivityAttributes(title: title)
        do {
            if #available(iOS 16.2, *) {
                _ = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(45)))
            } else {
                _ = try Activity.request(attributes: attributes, contentState: state)
            }
        } catch { }
    }
}
