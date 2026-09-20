import SwiftUI
import Security
import UserNotifications
import AVFoundation
import Network
import UIKit

struct FamilyAccount: Codable { let token: String; let user_id: String; let email: String }
struct SharedFamily: Codable, Identifiable { let id: String; let label: String; let owner: String; var role: String? }
struct FamilyMember: Codable, Identifiable { let id: String; let email: String; var role: String?; var relation: String? }

enum FamilyRelation: String, CaseIterable, Identifiable {
    case mum, dad, nan, auntie, uncle, carer
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mum: return "Mum"
        case .dad: return "Dad"
        case .nan: return "Nan"
        case .auntie: return "Auntie"
        case .uncle: return "Uncle"
        case .carer: return "Carer"
        }
    }
    var role: String { self == .carer ? "carer" : "watcher" }
    var hint: String {
        self == .carer
            ? "Their phone can be the one with the baby."
            : "They watch live readings on their iPhone."
    }
    static func sharedFrom(_ raw: String?, wifi: Bool) -> String {
        let who = FamilyRelation(rawValue: raw ?? "")?.title
        if let who {
            return wifi ? "Shared from \(who) on this Wi‑Fi" : "Shared from \(who)"
        }
        return wifi ? "Shared from family on this Wi‑Fi" : "Shared from family"
    }
}
struct FamilySample: Codable, Equatable {
    var t: Double
    var hr: Double?
    var o2: Double?
}
struct FamilySnapshot: Codable {
    var captured: Double
    var heart_rate: Double?
    var oxygen: Double?
    var heart_rate_at: Double?
    var oxygen_at: Double?
    var source: String
    var alarm: String
    var connection: String
    var history: [FamilySample] = []
    var stream_id: String?
    var seq: Int?
    var kind: String?
    var server_received: Double?
    var acknowledged: Bool?
    var activity_secret: String?
    var place: String?
    var host_relation: String?

    enum CodingKeys: String, CodingKey {
        case captured, heart_rate, oxygen, heart_rate_at, oxygen_at, source, alarm, connection, history, stream_id, seq, kind, server_received, acknowledged, activity_secret, place, host_relation
    }

    init(captured: Double, heart_rate: Double?, oxygen: Double?, source: String, alarm: String, connection: String, history: [FamilySample] = [], heart_rate_at: Double? = nil, oxygen_at: Double? = nil, stream_id: String? = nil, seq: Int? = nil, kind: String? = "live", acknowledged: Bool = false, activity_secret: String? = nil, place: String? = nil, host_relation: String? = nil) {
        self.captured = captured
        self.heart_rate = heart_rate
        self.oxygen = oxygen
        self.heart_rate_at = heart_rate_at
        self.oxygen_at = oxygen_at
        self.source = source
        self.alarm = alarm
        self.connection = connection
        self.history = history
        self.stream_id = stream_id
        self.seq = seq
        self.kind = kind
        self.acknowledged = acknowledged
        self.activity_secret = activity_secret
        self.place = place
        self.host_relation = host_relation
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        captured = try box.decode(Double.self, forKey: .captured)
        heart_rate = try box.decodeIfPresent(Double.self, forKey: .heart_rate)
        oxygen = try box.decodeIfPresent(Double.self, forKey: .oxygen)
        heart_rate_at = try box.decodeIfPresent(Double.self, forKey: .heart_rate_at)
        oxygen_at = try box.decodeIfPresent(Double.self, forKey: .oxygen_at)
        source = try box.decodeIfPresent(String.self, forKey: .source) ?? ""
        alarm = try box.decodeIfPresent(String.self, forKey: .alarm) ?? "none"
        connection = try box.decodeIfPresent(String.self, forKey: .connection) ?? ""
        history = try box.decodeIfPresent([FamilySample].self, forKey: .history) ?? []
        stream_id = try box.decodeIfPresent(String.self, forKey: .stream_id)
        seq = try box.decodeIfPresent(Int.self, forKey: .seq)
        kind = try box.decodeIfPresent(String.self, forKey: .kind)
        server_received = try box.decodeIfPresent(Double.self, forKey: .server_received)
        acknowledged = try box.decodeIfPresent(Bool.self, forKey: .acknowledged)
        activity_secret = try box.decodeIfPresent(String.self, forKey: .activity_secret)
        place = try box.decodeIfPresent(String.self, forKey: .place)
        host_relation = try box.decodeIfPresent(String.self, forKey: .host_relation)
    }
}
struct RemoteReading: Codable {
    let fresh: Bool
    let age: Double?
    let snapshot: FamilySnapshot?
    var heart_rate_fresh: Bool?
    var oxygen_fresh: Bool?
}
struct FamilyReply: Codable { var message: String?; var code: String?; var ok: Bool?; var seq: Int?; var server_received: Double? }

enum FamilyKeychain {
    static let service = "com.michael1991.nivvi.family"
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session"] }
    static func read() -> FamilyAccount? {
        var q = query; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(FamilyAccount.self, from: data)
    }
    static func save(_ account: FamilyAccount?) throws {
        SecItemDelete(query as CFDictionary)
        guard let account else { return }
        var q = query
        q[kSecValueData as String] = try JSONEncoder().encode(account)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw FamilyError.message("Could not save the sign-in securely.") }
    }
}
enum FamilyError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

@MainActor
final class FamilyRelay: ObservableObject {
    static let shared = FamilyRelay()
    @Published private(set) var account = FamilyKeychain.read()
    @Published private(set) var families: [SharedFamily] = []
    @Published private(set) var members: [FamilyMember] = []
    @Published private(set) var remote: RemoteReading?
    @Published private(set) var remoteFetched: Date?
    @Published var selected: String?
    @Published var message = ""
    @Published var busy = false
    @Published private(set) var publishing = false
    @Published private(set) var invitation: String?
    @Published private(set) var socketConnected = false
    @Published private(set) var lastLatency: TimeInterval?
    @Published private(set) var trail: [SavedMeasurement] = []
    @Published private(set) var alarmCatchup = true
    @Published private(set) var inboundAck = false
    private var lastUpload: Date?
    private var lastHistoryUpload: Date?
    private var lastAlarm = "none"
    private var appliedAlarm = "none"
    private var uploadBusy = false
    private var pendingSnapshot: FamilySnapshot?
    private var generation = UUID()
    private var deviceToken = UserDefaults.standard.string(forKey: "nivvi.family.apns")
    private var watchTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var socketFamily: String?
    private var lastSeq = 0
    private var currentStream: String?
    private var publishStream = UUID().uuidString
    private var uploadSeq = 0
    private var lastEventAt: Date?
    private var pathMonitor: NWPathMonitor?
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var watching = false
    private var ownFamily: SharedFamily? { families.first { $0.owner == account?.user_id } }
    private var publishFamilyID: String? {
        ownFamily?.id ?? families.first(where: { $0.id == selected && $0.role == "carer" })?.id
    }
    var isCarer: Bool { families.contains { $0.role == "carer" } }
    var isOwner: Bool { ownFamily != nil }
    var signedIn: Bool { account != nil }
    var userID: String? { account?.user_id }
    var followingFamily: Bool { signedIn && selected != nil && selected != ownFamily?.id }
    var familyHeartFresh: Bool {
        FamilyLivePolicy.metricFresh(at: Date(), stamped: remote?.snapshot?.heart_rate_at ?? remote?.snapshot?.captured, hasValue: remote?.snapshot?.heart_rate != nil)
    }
    var familyOxygenFresh: Bool {
        FamilyLivePolicy.metricFresh(at: Date(), stamped: remote?.snapshot?.oxygen_at ?? remote?.snapshot?.captured, hasValue: remote?.snapshot?.oxygen != nil)
    }
    var familyFresh: Bool { familyHeartFresh }
    var viewingRemote: Bool { followingFamily }
    var linkState: FamilyLinkState {
        FamilyLivePolicy.link(
            following: followingFamily,
            socketConnected: socketConnected,
            lastEvent: lastEventAt ?? remoteFetched,
            hostConnection: remote?.snapshot?.connection ?? "",
            heartFresh: familyHeartFresh,
            sensorAlarm: remote?.snapshot?.alarm == "sensor",
            now: Date()
        )
    }
    var statusLine: String {
        switch linkState {
        case .live: return FamilyRelation.sharedFrom(remote?.snapshot?.host_relation, wifi: false) + " · live"
        case .hostStale: return "Shared reading is stale · not live"
        case .sensorDisconnected: return "Sensor on the baby’s phone disconnected"
        case .viewerOffline: return "This phone lost the family link · not live"
        case .idle: return "Family sharing"
        }
    }
    var liveHeartRate: String? {
        guard followingFamily, familyHeartFresh, let value = remote?.snapshot?.heart_rate else { return nil }
        return "\(Int(value.rounded())) bpm"
    }
    var liveOxygen: String? {
        guard followingFamily, familyOxygenFresh, let value = remote?.snapshot?.oxygen else { return nil }
        return "\(Int(value.rounded()))%"
    }
    var privacyURL: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "NivviFamilyPrivacyURL") as? String, let u = URL(string: s), u.scheme == "https", u.host != nil else { return nil }
        return u
    }
    private var server: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "NivviFamilyServerURL") as? String, let u = URL(string: s), u.scheme == "https", u.host != nil, u.user == nil, u.password == nil else { return nil }
        return u
    }
    var configured: Bool { server != nil && privacyURL != nil }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = true, timeout: TimeInterval = 45) async throws -> T {
        guard configured, let server else { throw FamilyError.message("Family sharing needs the Nivvi online service to be configured.") }
        var req = URLRequest(url: server.appendingPathComponent(path))
        req.httpMethod = method; req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let current = account?.token
        if authenticated {
            guard let current else { throw FamilyError.message("Sign in to continue.") }
            req.setValue("Bearer " + current, forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let response = response as? HTTPURLResponse else { throw FamilyError.message("Sharing service unavailable.") }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 && authenticated && account?.token == current {
                publishing = false; account = nil; generation = UUID(); dropSocket(); clearRemote()
                families = []; members = []; invitation = nil; pendingSnapshot = nil
                try? FamilyKeychain.save(nil)
            }
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            throw FamilyError.message(detail ?? "Sharing request failed (\(response.statusCode)). Please try again.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func body(_ fields: [String: String]) throws -> Data { try JSONEncoder().encode(fields) }
    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; message = ""
        Task { do { try await operation() } catch { message = error.localizedDescription }; busy = false }
    }
    func authenticate(email: String, password: String, code: String, action: String) async throws {
        var fields = ["email": email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
        if ["login", "register", "reset", "verify"].contains(action) { fields["password"] = password }
        if ["verify", "reset"].contains(action) { fields["code"] = code }
        if action == "login" {
            let value: FamilyAccount = try await request("auth/login", method: "POST", body: body(fields), authenticated: false)
            try FamilyKeychain.save(value); account = value; generation = UUID()
            try await refreshFamilies()
            message = "Signed in. Sharing starts only when you enable it on this phone."
        } else {
            let result: FamilyReply = try await request("auth/" + action, method: "POST", body: body(fields), authenticated: false)
            message = result.message ?? "Done."
        }
    }
    func refreshFamilies() async throws {
        let token = generation
        let result: [SharedFamily] = try await request("families")
        guard token == generation else { return }
        families = result
        if !result.contains(where: { $0.id == selected }) { selected = result.first?.id; clearRemote() }
        if ownFamily == nil && !families.contains(where: { $0.role == "carer" }) { publishing = false }
    }
    func enable(label: String) async throws {
        if ownFamily == nil, families.contains(where: { $0.id == selected && $0.role == "carer" }) {
            publishing = true
            lastUpload = nil
            lastHistoryUpload = nil
            publishStream = UUID().uuidString
            uploadSeq = 0
            message = "This phone is with the baby. Parents see live numbers on theirs."
            return
        }
        let _: SharedFamily = try await request("families", method: "POST", body: body(["label": label]))
        try await refreshFamilies()
        publishing = true
        lastUpload = nil
        lastHistoryUpload = nil
        publishStream = UUID().uuidString
        uploadSeq = 0
        message = "Sharing enabled on this phone. Keep it near the wearable and connected to the internet."
    }
    func stop() async throws {
        publishing = false; generation = UUID(); invitation = nil
        if let family = ownFamily {
            let _: FamilyReply = try await request("families/" + family.id, method: "DELETE")
            try await refreshFamilies(); clearRemote(); members = []
            message = "Sharing stopped. Online snapshot, invitations and member access removed."
        } else {
            try await refreshFamilies()
            message = "This phone is no longer with the baby. Parents keep the family."
        }
    }
    func invite(email: String, role: String = "watcher", relation: String = "") async throws {
        guard let family = ownFamily else { throw FamilyError.message("Turn on sharing first — one tap above.") }
        let reply: FamilyReply = try await request("families/\(family.id)/invites", method: "POST", body: body(["email": email, "role": role, "relation": relation]))
        invitation = reply.code
        let who = FamilyRelation(rawValue: relation)?.title ?? "family"
        message = relation == "carer"
            ? "Send this to \(who). Their phone can stay with the baby."
            : "Send this to \(who). They open Nivvi, sign up with that email, and paste the code."
        try await refreshMembers()
    }
    func join(code: String) async throws {
        let _: FamilyReply = try await request("invites/accept", method: "POST", body: body(["code": code]))
        try await refreshFamilies()
        message = "You’re in. Live readings will show here when the phone with the baby is sharing."
        UIApplication.shared.registerForRemoteNotifications()
    }
    func refreshMembers() async throws {
        guard let family = ownFamily else { members = []; return }
        members = try await request("families/\(family.id)/members")
    }
    func revoke(_ member: FamilyMember) async throws {
        guard let family = ownFamily else { return }
        let _: FamilyReply = try await request("families/\(family.id)/members/\(member.id)", method: "DELETE")
        try await refreshMembers()
    }
    func leave() async throws {
        guard let selected, let user = account?.user_id else { return }
        let _: FamilyReply = try await request("families/\(selected)/members/\(user)", method: "DELETE")
        clearRemote(); try await refreshFamilies()
    }
    func startWatching() {
        if watching { return }
        watching = true
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self, path.status == .satisfied else { return }
                self.reconnectAttempt = 0
                self.reconnectTask?.cancel()
                self.reconnectTask = nil
                self.reconnectSocket()
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        pathMonitor = monitor
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tickWatch()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    func resumeForeground() {
        guard watching, followingFamily || publishing else { return }
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectSocket()
    }
    private func tickWatch() async {
        guard signedIn else { dropSocket(); return }
        if families.isEmpty {
            do { try await refreshFamilies() } catch { message = error.localizedDescription }
        }
        if followingFamily || publishing {
            if socket == nil { scheduleReconnect() }
            if followingFamily, !socketConnected { await fetchRemote() }
        } else {
            dropSocket()
        }
    }
    func clearRemote() {
        remote = nil
        remoteFetched = nil
        lastEventAt = nil
        lastLatency = nil
        trail = []
        lastSeq = 0
        currentStream = nil
        appliedAlarm = "none"
        alarmCatchup = true
    }
    func fetchRemote() async {
        guard signedIn, let selected else { clearRemote(); return }
        if socketConnected && remote != nil { return }
        let token = generation
        do {
            let value: RemoteReading = try await request("families/\(selected)/latest")
            guard token == generation && self.selected == selected else { return }
            if let snap = value.snapshot {
                applyRemote(snap, catchup: true, serverReceived: snap.server_received)
            } else {
                remote = value
                remoteFetched = Date()
            }
        } catch {
            message = error.localizedDescription
        }
    }
    func capture(_ snapshot: FamilySnapshot) {
        guard publishing, let familyID = publishFamilyID else { return }
        var next = snapshot
        if next.seq == nil {
            uploadSeq += 1
            next.seq = uploadSeq
            next.stream_id = publishStream
            next.kind = "live"
        }
        let includeHistory = lastHistoryUpload == nil || Date().timeIntervalSince(lastHistoryUpload!) >= 15
        if !includeHistory { next.history = [] }
        if uploadBusy { pendingSnapshot = next; return }
        let token = generation
        uploadBusy = true
        Task {
            defer {
                uploadBusy = false
                if let pending = pendingSnapshot { pendingSnapshot = nil; capture(pending) }
            }
            guard publishing && token == generation else { return }
            do {
                let reply: FamilyReply = try await request("families/\(familyID)/latest", method: "PUT", body: JSONEncoder().encode(next), timeout: 8)
                guard token == generation else { return }
                lastUpload = Date()
                lastAlarm = next.alarm
                if let received = reply.server_received {
                    lastLatency = received - next.captured
                }
                if includeHistory { lastHistoryUpload = Date() }
            } catch {
                let text = error.localizedDescription
                if text.contains("(409)") {
                    uploadSeq += 1
                    pendingSnapshot?.seq = uploadSeq
                    pendingSnapshot?.stream_id = publishStream
                }
                message = "Remote update unavailable: " + text
            }
        }
    }
    func saveDeviceToken(_ token: String) { deviceToken = token }
    func notifications() async throws {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        guard granted else { throw FamilyError.message("Enable notifications in iPhone Settings.") }
        UIApplication.shared.registerForRemoteNotifications()
        message = "Registering this phone for family updates. Notifications can be delayed or silenced by iOS."
    }
    func registerDevice(_ token: String) async {
        deviceToken = token
        UserDefaults.standard.set(token, forKey: "nivvi.family.apns")
        guard signedIn else { return }
        do { let _: FamilyReply = try await request("devices", method: "PUT", body: body(["token": token])); message = "This phone is registered for family notifications." }
        catch { message = error.localizedDescription }
    }
    private func socketURL(family: String) -> URL? {
        guard let server, let token = account?.token else { return nil }
        var parts = URLComponents(url: server.appendingPathComponent("families/\(family)/live"), resolvingAgainstBaseURL: false)
        parts?.scheme = server.scheme == "http" ? "ws" : "wss"
        parts?.queryItems = [URLQueryItem(name: "token", value: token)]
        return parts?.url
    }
    private func connectSocket() {
        let familyID = followingFamily ? selected : ownFamily?.id
        guard signedIn, let familyID, let url = socketURL(family: familyID), let token = account?.token else { return }
        if socket != nil, socketFamily == familyID { return }
        dropSocket(resetBackoff: false)
        var req = URLRequest(url: url)
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        let task = URLSession.shared.webSocketTask(with: req)
        socket = task
        socketFamily = familyID
        task.resume()
        listenSocket()
    }
    private func reconnectSocket() {
        guard followingFamily || publishing else { return }
        dropSocket(resetBackoff: false)
        connectSocket()
    }
    private func dropSocket(resetBackoff: Bool = true) {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        socketFamily = nil
        socketConnected = false
        if resetBackoff {
            reconnectAttempt = 0
            reconnectTask?.cancel()
            reconnectTask = nil
        }
    }
    private func scheduleReconnect() {
        guard (followingFamily || publishing), socket == nil, reconnectTask == nil else { return }
        reconnectAttempt += 1
        let delay = FamilyLivePolicy.reconnectDelay(attempt: reconnectAttempt)
        reconnectTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.reconnectTask = nil
                self.connectSocket()
            }
        }
    }
    private func listenSocket() {
        socket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure:
                    self.dropSocket(resetBackoff: false)
                    self.scheduleReconnect()
                case .success(let message):
                    self.socketConnected = true
                    self.reconnectAttempt = 0
                    self.applySocket(message)
                    self.listenSocket()
                }
            }
        }
    }
    private func applySocket(_ frame: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch frame {
        case .data(let value): data = value
        case .string(let value): data = value.data(using: .utf8)
        @unknown default: data = nil
        }
        guard let data, let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let type = raw["type"] as? String ?? ""
        if type == "ping" { return }
        if type == "revoked" {
            dropSocket(); clearRemote()
            self.message = "Family access ended."
            return
        }
        if type == "ack" {
            inboundAck = true
            if followingFamily, var snap = remote?.snapshot {
                snap.acknowledged = true
                applyRemote(snap, catchup: false, serverReceived: snap.server_received)
            }
            return
        }
        if !followingFamily {
            if raw["acknowledged"] as? Bool == true { inboundAck = true }
            return
        }
        var payload = data
        if type == "snapshot", let nested = raw["snapshot"] as? [String: Any], let nestedData = try? JSONSerialization.data(withJSONObject: nested) {
            payload = nestedData
        }
        guard let snap = try? JSONDecoder().decode(FamilySnapshot.self, from: payload) else { return }
        let event = FamilyLiveEvent(
            type: type.isEmpty ? "live" : type,
            streamID: snap.stream_id ?? "",
            seq: snap.seq ?? 0,
            captured: snap.captured,
            heartRate: snap.heart_rate,
            heartRateAt: snap.heart_rate_at,
            oxygen: snap.oxygen,
            oxygenAt: snap.oxygen_at,
            alarm: snap.alarm,
            connection: snap.connection,
            serverReceived: snap.server_received
        )
        let catchup = type == "snapshot"
        if event.seq > 0, FamilyLivePolicy.accept(currentStream: currentStream, lastSeq: lastSeq, incoming: event) == nil { return }
        applyRemote(snap, catchup: catchup, serverReceived: snap.server_received)
    }
    private func applyRemote(_ snap: FamilySnapshot, catchup: Bool, serverReceived: Double?) {
        if let stream = snap.stream_id, stream != currentStream {
            currentStream = stream
            lastSeq = 0
            trail = []
        }
        if catchup, trail.isEmpty, !snap.history.isEmpty {
            trail = SavedMeasurement.uniquelyIdentified(snap.history.map {
                SavedMeasurement.mapped(time: Date(timeIntervalSince1970: $0.t), heartRate: $0.hr, oxygen: $0.o2, source: "family-share")
            })
        }
        if let seq = snap.seq { lastSeq = seq }
        lastEventAt = Date()
        remoteFetched = Date()
        alarmCatchup = catchup
        if let received = serverReceived {
            lastLatency = Date().timeIntervalSince1970 - received
        }
        var merged = snap
        if snap.history.isEmpty, let existing = remote?.snapshot?.history {
            merged.history = existing
        }
        remote = RemoteReading(
            fresh: FamilyLivePolicy.metricFresh(at: Date(), stamped: snap.heart_rate_at ?? snap.captured, hasValue: snap.heart_rate != nil),
            age: snap.heart_rate_at.map { Date().timeIntervalSince1970 - $0 },
            snapshot: merged,
            heart_rate_fresh: FamilyLivePolicy.metricFresh(at: Date(), stamped: snap.heart_rate_at ?? snap.captured, hasValue: snap.heart_rate != nil),
            oxygen_fresh: FamilyLivePolicy.metricFresh(at: Date(), stamped: snap.oxygen_at ?? snap.captured, hasValue: snap.oxygen != nil)
        )
        if let hr = snap.heart_rate {
            let stamp = Date(timeIntervalSince1970: snap.heart_rate_at ?? snap.captured)
            let point = SavedMeasurement.mapped(time: stamp, heartRate: hr, oxygen: snap.oxygen, source: "family-share")
            if trail.last?.id != point.id {
                trail.append(point)
            }
            let cut = Date().addingTimeInterval(-120)
            trail.removeAll { $0.time < cut }
            if trail.count > 400 { trail.removeFirst(trail.count - 400) }
        }
        let nextAlarm = snap.alarm
        if FamilyLivePolicy.shouldSoundAlarm(catchup: catchup, previous: appliedAlarm, next: nextAlarm)
            || FamilyLivePolicy.shouldSoundRecovery(catchup: catchup, previous: appliedAlarm, next: nextAlarm, hasHeartRate: snap.heart_rate != nil) {
            alarmCatchup = false
        }
        appliedAlarm = nextAlarm
        if snap.acknowledged == true { inboundAck = true }
        if followingFamily { LiveActivityPush.rememberFollowSecret(snap.activity_secret) }
    }
    func consumeInboundAck() -> Bool {
        guard inboundAck else { return false }
        inboundAck = false
        return true
    }
    func acknowledgeAlarm() async {
        let familyID = followingFamily ? selected : ownFamily?.id
        guard signedIn, let familyID else { return }
        do {
            let _: FamilyReply = try await request("families/\(familyID)/ack", method: "POST")
        } catch {
            message = error.localizedDescription
        }
    }
    func signOut(delete: Bool = false) async throws {
        publishing = false; generation = UUID(); dropSocket(); clearRemote()
        if delete {
            let _: FamilyReply = try await request("account", method: "DELETE")
        } else {
            if let deviceToken { let _: FamilyReply = try await request("devices/" + deviceToken, method: "DELETE") }
            let _: FamilyReply = try await request("auth/logout", method: "POST")
        }
        try FamilyKeychain.save(nil); account = nil; families = []; members = []; invitation = nil
        message = delete ? "Online account and shared data deleted. Local history stays on this phone." : "Signed out. This phone no longer uploads."
    }
}

struct FamilySharingView: View {
    private enum AuthStep {
        case signIn, register, verify, resetRequest, reset
    }

    @ObservedObject private var relay = FamilyRelay.shared
    @ObservedObject private var wifi = WiFiRelay.shared
    @Environment(\.scenePhase) private var phase
    @Environment(\.colorScheme) private var scheme
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var label = "Family"
    @State private var inviteEmail = ""
    @State private var inviteRelation: FamilyRelation = .mum
    @State private var joinCode = ""
    @AppStorage("nivvi.profile.name") private var childName = ""
    @AppStorage("nivvi.host.relation") private var hostRelation = ""
    @State private var consent = false
    @State private var confirmDelete = false
    @State private var confirmStop = false
    @State private var showPassword = false
    @State private var step: AuthStep = .signIn
    @State private var pendingAction = ""
    @FocusState private var focus: Field?
    private enum Field { case email, password, code }

    private var accent: Color { scheme == .dark ? Color(red: 0.56, green: 0.89, blue: 0.82) : Color(red: 0.02, green: 0.42, blue: 0.40) }
    private var ink: Color { scheme == .dark ? .white : Color(red: 0.10, green: 0.14, blue: 0.18) }
    private var muted: Color { scheme == .dark ? Color.white.opacity(0.78) : Color(red: 0.28, green: 0.34, blue: 0.36) }
    private var sheetBg: Color { scheme == .dark ? Color(red: 0.06, green: 0.12, blue: 0.16) : Color(red: 0.93, green: 0.96, blue: 0.95) }
    private var fieldBg: Color { scheme == .dark ? Color.white.opacity(0.08) : Color.white }
    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmitPassword: Bool { trimmedEmail.contains("@") && password.count >= 12 }
    private var messageIsError: Bool {
        let text = relay.message.lowercased()
        guard !text.isEmpty else { return false }
        return text.contains("fail") || text.contains("invalid") || text.contains("unavailable") || text.contains("try again") || text.contains("too many")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !relay.configured {
                    wifiShortcut
                } else if !relay.signedIn {
                    authFlow
                } else {
                    signedIn
                }
                if let privacy = relay.privacyURL {
                    Link("Family-sharing privacy notice", destination: privacy)
                        .font(.footnote)
                        .foregroundStyle(muted)
                        .accessibilityHint("Opens the family sharing privacy notice in Safari")
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .background(sheetBg.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(relay.busy)
        .alert("Delete online account?", isPresented: $confirmDelete) {
            Button("Delete account", role: .destructive) { relay.perform { try await relay.signOut(delete: true) } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Removes your online account, owned sharing group and member access. Local history is kept.") }
        .alert("Stop sharing with everyone?", isPresented: $confirmStop) {
            Button("Stop and remove access", role: .destructive) { relay.perform { try await relay.stop() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Deletes the latest online snapshot and invitations. New invitations will be needed to share again.") }
        .task(id: "\(phase)-\(relay.signedIn)") {
            guard phase == .active, relay.configured, relay.signedIn else { return }
            do {
                try await relay.refreshFamilies()
                try await relay.refreshMembers()
            } catch { relay.message = error.localizedDescription }
            await relay.fetchRemote()
        }
        .onChange(of: relay.selected) { _ in Task { await relay.fetchRemote() } }
        .onChange(of: relay.signedIn) { signed in
            if !signed { step = .signIn; pendingAction = ""; code = "" }
        }
        .onChange(of: step) { _ in
            showPassword = false
            focus = step == .verify || step == .reset ? .code : .email
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "person.2.fill")
                    .font(.title3)
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text("Family Sharing")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(ink)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Text("Share your child’s readings with the people who care for them.")
                .font(.body)
                .foregroundStyle(ink)
            Text("Each family member needs their own account.")
                .font(.subheadline)
                .foregroundStyle(muted)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var authFlow: some View {
        switch step {
        case .signIn: signInStep
        case .register: registerStep
        case .verify: verifyStep
        case .resetRequest: resetRequestStep
        case .reset: resetStep
        }
    }

    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !relay.message.isEmpty && pendingAction != "login" {
                Text(relay.message)
                    .font(.callout)
                    .foregroundStyle(messageIsError ? Color.orange : accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            emailField(contentType: .username)
            passwordField(contentType: .password, hint: "At least 12 characters.")
            Button("Forgot password?") {
                relay.message = ""
                pendingAction = ""
                step = .resetRequest
            }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
                .accessibilityHint("Starts password reset")
            primaryButton("Sign in", action: "login", enabled: canSubmitPassword)
            status(for: "login")
            if relay.message.lowercased().contains("verify") && pendingAction == "login" {
                Button("I have a verification code") { step = .verify }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
            }
            Button("New to Nivvi? Create an account") {
                relay.message = ""
                pendingAction = ""
                step = .register
            }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(fieldBg)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ink.opacity(0.12), lineWidth: 1))
                .accessibilityHint("Opens account creation")
        }
    }

    private var registerStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create an account").font(.headline).foregroundStyle(ink)
            emailField(contentType: .username)
            passwordField(contentType: .newPassword, hint: "Choose a password of at least 12 characters.")
            primaryButton("Create account", action: "register", enabled: canSubmitPassword, next: .verify)
            status(for: "register")
            backToSignIn
        }
    }

    private var verifyStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Verify email").font(.headline).foregroundStyle(ink)
            Text("Paste the full code emailed to \(trimmedEmail.isEmpty ? "your email" : trimmedEmail). It is a long mix of letters and numbers, not a 6-digit PIN.")
                .font(.subheadline)
                .foregroundStyle(muted)
                .fixedSize(horizontal: false, vertical: true)
            if pendingAction == "register", !relay.message.isEmpty, !messageIsError {
                Text(relay.message)
                    .font(.callout)
                    .foregroundStyle(accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            codeField
            if password.count < 12 {
                passwordField(contentType: .password, hint: "The password for this account, at least 12 characters.")
            }
            primaryButton("Verify email", action: "verify", enabled: canSubmitPassword && !code.trimmingCharacters(in: .whitespaces).isEmpty, next: .signIn)
            status(for: "verify")
            Button("Resend code") { runAuth("register") }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
            status(for: "register")
            Button("Use a different email") { step = .register }
                .font(.subheadline)
                .foregroundStyle(muted)
            backToSignIn
        }
    }

    private var resetRequestStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Forgot password").font(.headline).foregroundStyle(ink)
            Text("We’ll email a reset code if this address has a Nivvi account. It will be a long code to paste, not 6 digits.")
                .font(.subheadline)
                .foregroundStyle(muted)
            emailField(contentType: .username)
            primaryButton("Send reset code", action: "reset-request", enabled: trimmedEmail.contains("@"), next: .reset)
            status(for: "reset-request")
            backToSignIn
        }
    }

    private var resetStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set a new password").font(.headline).foregroundStyle(ink)
            Text("Paste the full code emailed to \(trimmedEmail.isEmpty ? "your email" : trimmedEmail). It is a long mix of letters and numbers, not a 6-digit PIN.")
                .font(.subheadline)
                .foregroundStyle(muted)
            codeField
            passwordField(contentType: .newPassword, hint: "New password, at least 12 characters.")
            primaryButton("Save new password", action: "reset", enabled: canSubmitPassword && !code.trimmingCharacters(in: .whitespaces).isEmpty, next: .signIn)
            status(for: "reset")
            Button("Resend reset code") { runAuth("reset-request") }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accent)
            status(for: "reset-request")
            backToSignIn
        }
    }

    private var backToSignIn: some View {
        Button("Back to sign in") {
            relay.message = ""
            pendingAction = ""
            step = .signIn
        }
            .font(.subheadline)
            .foregroundStyle(muted)
            .padding(.top, 4)
            .accessibilityHint("Returns to the sign-in form")
    }

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(relay.account?.email ?? "")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(muted)
                .textSelection(.enabled)
            if relay.isOwner || relay.isCarer || relay.publishing || relay.families.isEmpty {
                ownerControls
            }
            if relay.followingFamily || relay.families.isEmpty {
                watchControls
            }
            Button("Turn on family alerts") { relay.perform { try await relay.notifications() } }
                .buttonStyle(.bordered)
            Text("Alerts can miss if a phone is locked, on Silent, or off the internet. This is not a medical monitor.")
                .font(.caption)
                .foregroundStyle(muted)
            HStack {
                Button("Sign out") { relay.perform { try await relay.signOut() } }
                Button("Delete account", role: .destructive) { confirmDelete = true }
            }
            .buttonStyle(.bordered)
            if !relay.message.isEmpty {
                Text(relay.message).font(.callout).foregroundStyle(messageIsError ? .orange : ink)
            }
            if relay.busy { ProgressView() }
        }
    }

    private var watchControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Watch live readings").font(.headline)
            if relay.families.isEmpty {
                Text("Someone sends you a code. Sign up with the same email they invited, then paste it here.")
                    .font(.subheadline)
                    .foregroundStyle(muted)
                labeled("Invite code") {
                    TextField("Paste the full code", text: $joinCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                }
                Button {
                    relay.perform { try await relay.join(code: joinCode); joinCode = "" }
                } label: {
                    Text("Join family").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(joinCode.trimmingCharacters(in: .whitespaces).count < 20 || relay.busy)
            } else {
                remoteControls
            }
        }
    }

    private func emailField(contentType: UITextContentType) -> some View {
        labeled("Email address") {
            TextField("name@example.com", text: $email)
                .textContentType(contentType)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .email)
                .onSubmit { focus = .password }
        }
    }

    private func passwordField(contentType: UITextContentType, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            labeled("Password") {
                HStack(spacing: 8) {
                    Group {
                        if showPassword {
                            TextField("Password", text: $password)
                        } else {
                            SecureField("Password", text: $password)
                        }
                    }
                    .textContentType(contentType)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focus, equals: .password)
                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundStyle(muted)
                    }
                    .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                }
            }
            Text(hint).font(.caption).foregroundStyle(muted)
        }
    }

    private var codeField: some View {
        labeled("Code from email") {
            TextField("Paste the full code", text: $code)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .focused($focus, equals: .code)
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ink)
            content()
                .padding(12)
                .background(fieldBg)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ink.opacity(0.12), lineWidth: 1))
        }
    }

    private func primaryButton(_ title: String, action: String, enabled: Bool, next: AuthStep? = nil) -> some View {
        Button {
            runAuth(action, next: next)
        } label: {
            HStack(spacing: 8) {
                if relay.busy && pendingAction == action { ProgressView().tint(.white) }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(enabled && !relay.busy ? accent : accent.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .disabled(!enabled || relay.busy)
    }

    @ViewBuilder private func status(for action: String) -> some View {
        if pendingAction == action {
            if relay.busy {
                Label("Please wait", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(muted)
            } else if !relay.message.isEmpty {
                Text(relay.message)
                    .font(.callout)
                    .foregroundStyle(messageIsError ? Color.orange : accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(relay.message)
            }
        }
    }

    private func runAuth(_ action: String, next: AuthStep? = nil) {
        pendingAction = action
        focus = nil
        relay.perform {
            try await relay.authenticate(email: email, password: password, code: code, action: action)
            if action == "login" || action == "reset" { password = ""; code = "" }
            if action == "verify" { code = "" }
            if let next { step = next }
        }
    }

    private var wifiShortcut: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Works on this Wi‑Fi tonight").font(.headline)
            Text("There is no Apple shortcut and no online server yet. Two iPhones on the same home Wi‑Fi can still share live numbers: one stays in the room on Bluetooth, the other follows downstairs.")
            Toggle("Share from this iPhone", isOn: Binding(get: { wifi.hosting }, set: { wifi.setHosting($0) }))
            if wifi.hosting {
                Text(wifi.pin).font(.system(size: 36, weight: .bold, design: .rounded)).monospacedDigit()
                Text("Do not type on this phone. Open Nivvi on the other iPhone and enter this code.")
            }
            TextField("4-digit code from the other iPhone", text: Binding(get: { wifi.joinPin }, set: { wifi.setJoinPin($0) }))
                .keyboardType(.numberPad)
                .font(.title3.monospacedDigit())
            Toggle("Follow the phone with the baby", isOn: Binding(get: { wifi.following }, set: { wifi.setFollowing($0) }))
            Text(wifi.status).font(.caption)
            Text("Seeing it from another house needs a paid always-on server. iCloud Family Sharing does not copy Nivvi readings.")
                .font(.caption)
        }
    }

    private var ownerControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share with family").font(.headline)
            Text("This phone stays with the baby. Family open Nivvi on theirs.")
                .font(.subheadline)
                .foregroundStyle(muted)
            labeled("This phone is") {
                Picker("This phone is", selection: $hostRelation) {
                    Text("Choose…").tag("")
                    ForEach(FamilyRelation.allCases) { relation in
                        Text(relation.title).tag(relation.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle("I can share these readings", isOn: $consent)
            if relay.isCarer && !relay.isOwner {
                Button {
                    relay.perform { try await relay.enable(label: label) }
                } label: {
                    Text("I’m with the baby")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(!consent || relay.busy)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    labeled("Who are they?") {
                        Picker("Relationship", selection: $inviteRelation) {
                            ForEach(FamilyRelation.allCases) { relation in
                                Text(relation.title).tag(relation)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(inviteRelation.hint).font(.caption).foregroundStyle(muted)
                    labeled("Their email") {
                        TextField("name@example.com", text: $inviteEmail)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.emailAddress)
                    }
                    Button {
                        relay.perform {
                            if !relay.isOwner && !relay.isCarer { try await relay.enable(label: label) }
                            try await relay.invite(email: inviteEmail, role: inviteRelation.role, relation: inviteRelation.rawValue)
                        }
                    } label: {
                        Text("Invite \(inviteRelation.title)")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
                    .disabled(!consent || !inviteEmail.contains("@") || relay.busy)
                    if let invitation = relay.invitation {
                        Text("Send this in Messages. They must use \(inviteEmail.isEmpty ? "that email" : inviteEmail).")
                            .font(.caption)
                            .foregroundStyle(muted)
                        ShareLink(item: inviteMessage(code: invitation)) {
                            Label("Send to \(inviteRelation.title)", systemImage: "square.and.arrow.up")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                    }
                }
            }
            if !relay.members.isEmpty {
                Text("Family").font(.subheadline.weight(.semibold))
                ForEach(relay.members) { member in
                    HStack {
                        Text(FamilyRelation(rawValue: member.relation ?? "")?.title ?? "Family")
                            .font(.subheadline.weight(.semibold))
                        Text(member.email).font(.caption).foregroundStyle(muted)
                        Spacer()
                        Button("Remove", role: .destructive) { relay.perform { try await relay.revoke(member) } }
                            .font(.caption)
                    }
                }
            }
            if relay.isOwner {
                Button("Stop sharing", role: .destructive) { confirmStop = true }
            }
        }
    }

    private func inviteMessage(code: String) -> String {
        let child = childName.isEmpty ? "the baby" : childName
        return """
        You’re invited to Nivvi as \(inviteRelation.title), to see \(child)’s live heart rate.

        1. Install Nivvi
        2. Create an account with this email: \(inviteEmail)
        3. Settings → Family sharing → paste this code:

        \(code)

        The code lasts 24 hours.
        """
    }

    private var remoteControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shared readings").font(.headline)
            Picker("Family", selection: $relay.selected) {
                ForEach(relay.families) { family in Text(family.label).tag(Optional(family.id)) }
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(relay.statusLine).font(.headline).foregroundStyle(relay.linkState == .live ? .green : .orange)
                if let snapshot = relay.remote?.snapshot {
                    HStack {
                        metric("Heart rate", relay.familyHeartFresh ? snapshot.heart_rate : nil, "bpm")
                        metric("Oxygen", relay.familyOxygenFresh ? snapshot.oxygen : nil, "%")
                    }
                    Text("Heart rate \(relay.familyHeartFresh ? "fresh" : "stale") · oxygen \(relay.familyOxygenFresh ? "fresh" : "stale")").font(.caption)
                    Text("Recorded \(Date(timeIntervalSince1970: snapshot.heart_rate_at ?? snapshot.captured).formatted(date: .abbreviated, time: .standard))").font(.caption.bold())
                    Text(snapshot.connection).font(.caption)
                    Text("Source: \(snapshot.source) · seq \(snapshot.seq.map(String.init) ?? "—")").font(.caption)
                    if let delay = relay.lastLatency {
                        Text(String(format: "Last hop %.2fs after the server", delay)).font(.caption)
                    }
                    if relay.linkState == .live && snapshot.alarm != "none" { Text(snapshot.alarm == "sensor" ? "Check sensor data" : "Shared monitor needs attention").foregroundStyle(.orange) }
                }
            }
            Button("Refresh now") { Task { await relay.fetchRemote() } }
            if let f = relay.families.first(where: { $0.id == relay.selected }), f.owner != relay.userID {
                Button("Leave this family", role: .destructive) { relay.perform { try await relay.leave() } }
            }
        }
        .buttonStyle(.bordered)
    }

    private func metric(_ title: String, _ value: Double?, _ unit: String) -> some View {
        VStack(alignment: .leading) { Text(title).font(.caption); Text(value.map { String(format: "%.0f %@", $0, unit) } ?? "—").font(.title2.bold()) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

