import Foundation
import ActivityKit

enum LiveActivityPush {
    private static let secretKey = "nivvi.activity.secret"
    private static let followKey = "nivvi.activity.followSecret"
    private static var lastPublish = Date.distantPast
    private static var uploadSeq = 0
    private static var lastToken = ""
    private static var watching = false

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

    static func rememberFollowSecret(_ value: String?) {
        guard let value, value.count >= 16 else { return }
        if followSecret != value {
            followSecret = value
            lastToken = ""
        }
        Task { await registerStoredToken() }
    }

    static func publish(title: String, heartRate: String, oxygen: String, connection: String, measuredAt: Date, session: String) {
        uploadSeq += 1
        let seq = uploadSeq
        let measured = measuredAt.timeIntervalSince1970
        let now = Date()
        if now.timeIntervalSince(lastPublish) < 1 { return }
        lastPublish = now
        let body: [String: Any] = [
            "secret": secret,
            "seq": seq,
            "measured_at": measured,
            "heart_rate": heartRate,
            "oxygen": oxygen,
            "connection": connection,
            "session": session,
            "title": title
        ]
        Task { await post("live-activity/publish", body: body) }
    }

    @available(iOS 16.1, *)
    static func watch(_ activity: Activity<NivviActivityAttributes>) {
        guard #available(iOS 16.2, *) else { return }
        guard !watching else { return }
        watching = true
        Task {
            for await token in activity.pushTokenUpdates {
                let hex = token.map { String(format: "%02x", $0) }.joined()
                lastToken = hex
                UserDefaults.standard.set(hex, forKey: "nivvi.activity.token")
                await register(hex)
            }
        }
    }

    static func registerStoredToken() async {
        let token = lastToken.isEmpty ? (UserDefaults.standard.string(forKey: "nivvi.activity.token") ?? "") : lastToken
        guard !token.isEmpty else { return }
        await register(token)
    }

    private static func register(_ token: String) async {
        guard let secret = followSecret, secret.count >= 16 else { return }
        await post("live-activity/token", body: ["secret": secret, "token": token])
    }

    private static func post(_ path: String, body: [String: Any]) async {
        guard let root = Bundle.main.object(forInfoDictionaryKey: "NivviFamilyServerURL") as? String,
              let url = URL(string: root)?.appendingPathComponent(path) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }
}
