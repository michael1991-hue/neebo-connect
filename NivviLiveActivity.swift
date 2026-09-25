import Foundation
import ActivityKit
import UIKit

enum NivviLiveActivityBridge {
    private static var lastPush = Date.distantPast
    private static var lastStale = false
    private static var lastRestart = Date.distantPast
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

    static func sync(title: String, heartRate: String, oxygen: String, connection: String, signal: String, nurseryHint: String, monitoring: Bool, measuredAt: Date = Date(), seq: Int = 0, session: String = "", stale: Bool = false, alarm: String = "") {
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
            alarm: alarm
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
        if let activity = Activity<NivviActivityAttributes>.activities.first {
            LiveActivityPush.watch(activity)
            if #available(iOS 16.2, *), restartIfStale(activity, measuredAt: measuredAt.timeIntervalSince1970, state: state, attributesTitle: title) {
                return
            }
            if !urgent, Date().timeIntervalSince(lastPush) < 5 { return }
            lastPush = Date()
            lastStale = stale
            let background = UIApplication.shared.beginBackgroundTask(withName: "nivvi.lock-screen") { }
            Task {
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

    @available(iOS 16.2, *)
    private static func restartIfStale(_ activity: Activity<NivviActivityAttributes>, measuredAt: TimeInterval, state: NivviActivityAttributes.ContentState, attributesTitle: String) -> Bool {
        guard !preferLocalBluetooth else { return false }
        guard Date().timeIntervalSince(lastRestart) > 180 else { return false }
        guard measuredAt > 0, Date().timeIntervalSince1970 - measuredAt < 30 else { return false }
        let shown = activity.content.state.measuredAt
        guard shown > 0, Date().timeIntervalSince1970 - shown > 90 else { return false }
        lastRestart = Date()
        lastPush = Date()
        let attributes = NivviActivityAttributes(title: attributesTitle)
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            if let replacement = try? Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: freshUntil(measuredAt, stale: state.stale)),
                pushType: .token
            ) {
                LiveActivityPush.watch(replacement)
            }
        }
        return true
    }

    private static func freshUntil(_ measuredAt: TimeInterval, stale: Bool) -> Date {
        if stale { return Date() }
        let measured = measuredAt > 0 ? Date(timeIntervalSince1970: measuredAt) : Date()
        return measured.addingTimeInterval(45)
    }
}
