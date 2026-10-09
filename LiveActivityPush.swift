import Foundation
import ActivityKit
import UIKit

enum LiveActivityPush {
    private static let secretKey = "nivvi.activity.secret"
    private static let followKey = "nivvi.activity.followSecret"
    private static var lastPublish = Date.distantPast
    private static var lastSentHeart = ""
    private static var lastSentOxygen = ""
    private static var uploadSeq = 0
    private static var lastToken = ""
    private static var watching = false
    private static var watchGeneration = 0
    private static var localOwner = false
    private static var familyID = ""

    static var secret: String {
        if let saved = UserDefaults.standard.string(forKey: secretKey), saved.count >= 16 { return saved }
        let created = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(created, forKey: secretKey)
        return created
    }

    static var followSecret: String? {
        get { UserDefaults.standard.string(forKey: followKey) }
        set { UserDefaults.standard.set(newValue, forKey: followKey) }
    }

    static func watchFamily(_ id: String?) {
        let next = id ?? ""
        guard next != familyID else { return }
        familyID = next
        Task { await registerStoredToken() }
    }

    static func claimLocal() {
        let first = !localOwner
        localOwner = true
        let token = lastToken.isEmpty ? (UserDefaults.standard.string(forKey: "nivvi.activity.token") ?? "") : lastToken
        let previous = followSecret
        followSecret = nil
        guard first else { return }
        Task {
            if let previous, previous != secret, !token.isEmpty {
                await send("DELETE", path: "live-activity/token", body: ["secret": previous, "token": token])
            }
            if !token.isEmpty {
                await send("POST", path: "live-activity/token", body: ["secret": secret, "token": token, "kind": "host"])
            }
        }
    }

    static func rememberFollowSecret(_ value: String?) {
        guard let value, value.count >= 16 else { return }
        localOwner = false
        if followSecret != value {
            followSecret = value
            lastToken = ""
        }
        Task { await registerStoredToken() }
    }

    static func publish(title: String, heartRate: String, oxygen: String, connection: String, measuredAt: Date, session: String, sleep: String = "") {
        let now = Date()
        let changed = heartRate != lastSentHeart || oxygen != lastSentOxygen
        let elapsed = now.timeIntervalSince(lastPublish)
        // A push every second makes Apple drop them, so the watching lock
        // screen then sits for minutes even though this phone is live.
        if changed {
            if elapsed < 4 { return }
        } else if elapsed < 8 {
            return
        }
        lastPublish = now
        lastSentHeart = heartRate
        lastSentOxygen = oxygen
        uploadSeq += 1
        let seq = uploadSeq
        let measured = measuredAt.timeIntervalSince1970
        let body: [String: Any] = [
            "secret": secret,
            "seq": seq,
            "measured_at": measured,
            "heart_rate": heartRate,
            "oxygen": oxygen,
            "connection": connection,
            "session": session,
            "title": title,
            "sleep": sleep
        ]
        let task = UIApplication.shared.beginBackgroundTask(withName: "nivvi.lock-push") {}
        Task {
            await post("live-activity/publish", body: body)
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }

    @available(iOS 16.1, *)
    static func watch(_ activity: Activity<NivviActivityAttributes>) {
        guard #available(iOS 16.2, *) else { return }
        guard !watching else { return }
        watching = true
        let generation = watchGeneration
        Task {
            for await token in activity.pushTokenUpdates {
                guard generation == watchGeneration else { return }
                let hex = token.map { String(format: "%02x", $0) }.joined()
                lastToken = hex
                UserDefaults.standard.set(hex, forKey: "nivvi.activity.token")
                await register(hex)
            }
        }
    }

    static func allowNextWatch() {
        watchGeneration += 1
        watching = false
    }

    static func registerStoredToken() async {
        let token = lastToken.isEmpty ? (UserDefaults.standard.string(forKey: "nivvi.activity.token") ?? "") : lastToken
        guard !token.isEmpty else { return }
        await register(token)
    }

    private static func register(_ token: String) async {
        let family = familyID
        if let follow = followSecret, follow.count >= 16, !NivviLiveActivityBridge.preferLocalBluetooth {
            localOwner = false
            await send("POST", path: "live-activity/token", body: ["secret": follow, "token": token, "kind": "watcher", "family": family])
            return
        }
        if !family.isEmpty {
            await send("POST", path: "live-activity/token", body: ["secret": secret, "token": token, "kind": "watcher", "family": family])
            return
        }
        guard localOwner || NivviLiveActivityBridge.preferLocalBluetooth else { return }
        localOwner = true
        await send("POST", path: "live-activity/token", body: ["secret": secret, "token": token, "kind": "host", "family": family])
    }

    private static func post(_ path: String, body: [String: Any]) async {
        await send("POST", path: path, body: body)
    }

    private static func send(_ method: String, path: String, body: [String: Any]) async {
        guard let root = Bundle.main.object(forInfoDictionaryKey: "NivviFamilyServerURL") as? String,
              let url = URL(string: root)?.appendingPathComponent(path) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }
}
