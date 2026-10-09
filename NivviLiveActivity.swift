import Foundation
import ActivityKit
import UIKit

enum NivviLiveActivityBridge {
    private static var lastPush = Date.distantPast
    private static var lastStale = false
    static var lastTitle = "Nivvi"
    static var preferLocalBluetooth = false

    static func syncShare(heartRate: String, oxygen: String, linked: Bool, status: String, measuredAt: Date = Date(), seq: Int = 0, session: String? = nil) {
        guard !preferLocalBluetooth else { return }
        sync(
            title: lastTitle,
            heartRate: heartRate,
            oxygen: oxygen,
            connection: linked ? "Shared over Wi‑Fi" : status,
            signal: "Wi‑Fi",
            nurseryHint: linked ? "" : status,
            monitoring: true,
            measuredAt: measuredAt,
            seq: seq,
            session: session ?? lastTitle
        )
    }

    static func sync(title: String, heartRate: String, oxygen: String, connection: String, signal: String, nurseryHint: String, monitoring: Bool, measuredAt: Date = Date(), seq: Int = 0, session: String = "", stale: Bool = false, alarm: String = "", forceNew: Bool = false, sleep: String = "", sleepStarted: TimeInterval = 0) {
        lastTitle = title
        guard #available(iOS 16.1, *) else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = NivviActivityAttributes.ContentState(
            heartRate: heartRate,
            oxygen: oxygen,
            connection: connection,
            signal: signal,
            nurseryHint: nurseryHint,
            captured: measuredAt.timeIntervalSince1970,
            measuredAt: measuredAt.timeIntervalSince1970,
            seq: seq,
            session: session.isEmpty ? title : session,
            stale: stale,
            alarm: alarm,
            sleep: sleep,
            sleepStarted: sleepStarted
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
        let urgent = stale != lastStale
        if !forceNew, let activity = Activity<NivviActivityAttributes>.activities.first {
            LiveActivityPush.watch(activity)
            if !urgent, Date().timeIntervalSince(lastPush) < (preferLocalBluetooth ? 2 : 1) { return }
            lastPush = Date()
            lastStale = stale
            let background = UIApplication.shared.beginBackgroundTask(withName: "nivvi.lock-screen") { }
            Task { @MainActor in
                defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
                if #available(iOS 16.2, *) {
                    await activity.update(ActivityContent(state: state, staleDate: freshUntil(measuredAt.timeIntervalSince1970, stale: stale)))
                } else {
                    await activity.update(using: state)
                }
            }
            return
        }
        lastPush = Date()
        lastStale = stale
        let attributes = NivviActivityAttributes(title: title)
        do {
            if #available(iOS 16.2, *) {
                let activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: freshUntil(measuredAt.timeIntervalSince1970, stale: stale)),
                    pushType: .token
                )
                LiveActivityPush.watch(activity)
            } else {
                _ = try Activity.request(attributes: attributes, contentState: state)
            }
        } catch {
            if #available(iOS 16.2, *) {
                if let activity = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: freshUntil(measuredAt.timeIntervalSince1970, stale: stale))) {
                    LiveActivityPush.watch(activity)
                }
            }
        }
    }

    static var cardRunning: Bool {
        guard #available(iOS 16.1, *) else { return false }
        return !Activity<NivviActivityAttributes>.activities.isEmpty
    }

    /// The in-app reading is live, but the lock-screen card is old or duplicated.
    static func lockScreenNeedsRestart() -> Bool {
        guard #available(iOS 16.2, *) else { return false }
        let activities = Activity<NivviActivityAttributes>.activities
        if activities.count > 1 { return true }
        guard let activity = activities.first else { return false }
        if activity.activityState == .stale || activity.content.state.stale { return true }
        if let until = activity.content.staleDate, until <= Date() { return true }
        let measured = activity.content.state.measuredAt
        return measured > 0 && Date().timeIntervalSince1970 - measured > 90
    }

    @MainActor
    static func restart() async {
        guard #available(iOS 16.1, *) else { return }
        for activity in Activity<NivviActivityAttributes>.activities {
            if #available(iOS 16.2, *) {
                await activity.end(nil, dismissalPolicy: .immediate)
            } else {
                await activity.end(dismissalPolicy: .immediate)
            }
        }
        lastPush = .distantPast
        LiveActivityPush.allowNextWatch()
    }

    private static func freshUntil(_ measuredAt: TimeInterval, stale: Bool) -> Date {
        if stale { return Date() }
        let until = Date().addingTimeInterval(600)
        return until
    }
}
