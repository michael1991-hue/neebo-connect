import SwiftUI
import Security
import UserNotifications

struct FamilyAccount: Codable { let token: String; let user_id: String; let email: String }
struct SharedFamily: Codable, Identifiable { let id: String; let label: String; let owner: String }
struct FamilyMember: Codable, Identifiable { let id: String; let email: String }
struct FamilySnapshot: Codable {
    var captured: Double
    var heart_rate: Double?
    var oxygen: Double?
    var source: String
    var alarm: String
    var connection: String
}
struct RemoteReading: Codable { let fresh: Bool; let age: Double?; let snapshot: FamilySnapshot? }
struct FamilyReply: Codable { var message: String?; var code: String?; var ok: Bool? }

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
    @Published var invitation: String?
    private var lastUpload: Date?
    private var lastAlarm = "none"
    private var uploadBusy = false
    private var pendingSnapshot: FamilySnapshot?
    private var generation = UUID()
    private var deviceToken = UserDefaults.standard.string(forKey: "nivvi.family.apns")
    private var ownFamily: SharedFamily? { families.first { $0.owner == account?.user_id } }
    var signedIn: Bool { account != nil }
    var userID: String? { account?.user_id }
    var privacyURL: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "NivviFamilyPrivacyURL") as? String, let u = URL(string: s), u.scheme == "https", u.host != nil else { return nil }
        return u
    }
    private var server: URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "NivviFamilyServerURL") as? String, let u = URL(string: s), u.scheme == "https", u.host != nil, u.user == nil, u.password == nil else { return nil }
        return u
    }
    var configured: Bool { server != nil && privacyURL != nil }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = true) async throws -> T {
        guard configured, let server else { throw FamilyError.message("Family sharing needs the Nivvi online service to be configured.") }
        var req = URLRequest(url: server.appendingPathComponent(path))
        req.httpMethod = method; req.timeoutInterval = 15
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
                publishing = false; account = nil; generation = UUID(); clearRemote()
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
        if ownFamily == nil { publishing = false }
    }
    func enable(label: String) async throws {
        let _: SharedFamily = try await request("families", method: "POST", body: body(["label": label]))
        try await refreshFamilies()
        publishing = true; lastUpload = nil
        message = "Sharing enabled on this phone. Keep it near the wearable and connected to the internet."
    }
    func stop() async throws {
        publishing = false; generation = UUID(); invitation = nil
        if let family = ownFamily {
            let _: FamilyReply = try await request("families/" + family.id, method: "DELETE")
        }
        try await refreshFamilies(); clearRemote(); members = []
        message = "Sharing stopped. Online snapshot, invitations and member access removed."
    }
    func invite(email: String) async throws {
        guard let family = ownFamily else { throw FamilyError.message("Enable sharing first.") }
        let reply: FamilyReply = try await request("families/\(family.id)/invites", method: "POST", body: body(["email": email]))
        invitation = reply.code
        message = "Give this private code to that person. It expires in 24 hours and only their verified email can accept it."
    }
    func join(code: String) async throws {
        let _: FamilyReply = try await request("invites/accept", method: "POST", body: body(["code": code]))
        try await refreshFamilies(); message = "Invitation accepted. You have read-only access."
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
    func clearRemote() { remote = nil; remoteFetched = nil }
    func fetchRemote() async {
        guard signedIn, let selected else { clearRemote(); return }
        let token = generation
        do {
            let value: RemoteReading = try await request("families/\(selected)/latest")
            guard token == generation && self.selected == selected else { return }
            remote = value; remoteFetched = Date()
        } catch { clearRemote(); message = error.localizedDescription }
    }
    func capture(_ snapshot: FamilySnapshot) {
        guard publishing, let family = ownFamily else { return }
        if uploadBusy { pendingSnapshot = snapshot; return }
        if snapshot.alarm == lastAlarm, let lastUpload, Date().timeIntervalSince(lastUpload) < 10 { return }
        let token = generation
        uploadBusy = true
        Task {
            defer {
                uploadBusy = false
                if let pending = pendingSnapshot { pendingSnapshot = nil; capture(pending) }
            }
            guard publishing && token == generation else { return }
            do {
                let _: FamilyReply = try await request("families/\(family.id)/latest", method: "PUT", body: JSONEncoder().encode(snapshot))
                guard token == generation else { return }
                lastUpload = Date(); lastAlarm = snapshot.alarm
            } catch { message = "Remote update unavailable: " + error.localizedDescription }
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
    func signOut(delete: Bool = false) async throws {
        publishing = false; generation = UUID(); clearRemote()
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
    @ObservedObject private var relay = FamilyRelay.shared
    @Environment(\.scenePhase) private var phase
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var label = "Family"
    @State private var inviteEmail = ""
    @State private var joinCode = ""
    @State private var consent = false
    @State private var confirmDelete = false
    @State private var confirmStop = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Family sharing").font(.largeTitle.bold())
                if !relay.configured {
                    Text("Online setup pending").font(.headline)
                    Text("This build includes family sharing, but the online service has not been configured. Local monitoring still works.")
                } else if !relay.signedIn {
                    Text("Sign in with your own verified email address. Family members use separate accounts.")
                    TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password (12 characters minimum)", text: $password).textContentType(.password)
                    TextField("Verification or reset code", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack { authButton("Sign in", "login"); authButton("Create account", "register") }
                    authButton("Verify email", "verify")
                    DisclosureGroup("Forgot password?") {
                        authButton("Send reset code", "reset-request")
                        authButton("Set password using code", "reset")
                    }
                } else {
                    Text(relay.account?.email ?? "").font(.subheadline)
                    ownerControls
                    Divider()
                    Text("Join a family").font(.headline)
                    TextField("Private invitation code", text: $joinCode).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Accept invitation") { relay.perform { try await relay.join(code: joinCode); joinCode = "" } }
                    if !relay.families.isEmpty { remoteControls }
                    Button("Enable family notifications") { relay.perform { try await relay.notifications() } }
                    Text("Remote updates are supplementary. Internet, phone background limits, Silent mode and Focus can delay or prevent alerts. No Critical Alerts permission is included.").font(.caption)
                    HStack {
                        Button("Sign out") { relay.perform { try await relay.signOut() } }
                        Button("Delete online account", role: .destructive) { confirmDelete = true }
                    }
                }
                if let privacy = relay.privacyURL { Link("Family-sharing privacy notice", destination: privacy) }
                if !relay.message.isEmpty { Text(relay.message).font(.callout).accessibilityLabel(relay.message) }
                if relay.busy { ProgressView() }
            }.padding().textFieldStyle(.roundedBorder).buttonStyle(.bordered).disabled(relay.busy)
        }
        .navigationTitle("Family")
        .alert("Delete online account?", isPresented: $confirmDelete) {
            Button("Delete account", role: .destructive) { relay.perform { try await relay.signOut(delete: true) } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Removes your online account, owned sharing group and member access. Local history is kept.") }
        .alert("Stop sharing with everyone?", isPresented: $confirmStop) {
            Button("Stop and remove access", role: .destructive) { relay.perform { try await relay.stop() } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Deletes the latest online snapshot and invitations. New invitations will be needed to share again.") }
        .task(id: "\(phase)-\(relay.signedIn)") {
            guard phase == .active, relay.configured, relay.signedIn else { relay.clearRemote(); return }
            do { try await relay.refreshFamilies() } catch { relay.message = error.localizedDescription }
            while !Task.isCancelled {
                await relay.fetchRemote()
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { break }
            }
            relay.clearRemote()
        }
        .onChange(of: relay.selected) { _ in relay.clearRemote(); Task { await relay.fetchRemote() } }
        .onDisappear { relay.clearRemote() }
    }
    private func authButton(_ title: String, _ action: String) -> some View {
        Button(title) { relay.perform {
            try await relay.authenticate(email: email, password: password, code: code, action: action)
            if action == "login" { password = ""; code = "" }
        } }
    }
    private var ownerControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Share from this phone").font(.headline)
            Text("Only the latest readings, source, status, alert state and your chosen family label are uploaded. Photos, birth dates, notes and historical readings are not shared. The latest snapshot expires after 24 hours; you can revoke access or stop sharing at any time.").font(.caption)
            TextField("Family label (use a nickname)", text: $label)
            Toggle("I have authority to share these readings and agree to the family privacy notice", isOn: $consent)
            Button(relay.publishing ? "Uploading from this phone" : "Enable sharing on this phone") { relay.perform { try await relay.enable(label: label) } }.disabled(!consent || relay.publishing)
            if relay.families.contains(where: { $0.owner == relay.userID }) {
                Button("Stop sharing and remove all access", role: .destructive) { confirmStop = true }
                TextField("Family member's email", text: $inviteEmail).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Create private invitation") { relay.perform { try await relay.invite(email: inviteEmail) } }
                if let invitation = relay.invitation { ShareLink("Share invitation code", item: invitation) }
                Button("Manage members") { relay.perform { try await relay.refreshMembers() } }
                ForEach(relay.members) { member in
                    HStack { Text(member.email); Spacer(); Button("Remove", role: .destructive) { relay.perform { try await relay.revoke(member) } } }
                }
            }
        }
    }
    private var remoteControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shared readings").font(.headline)
            Picker("Family", selection: $relay.selected) {
                ForEach(relay.families) { family in Text(family.label).tag(Optional(family.id)) }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = relay.remoteFetched.map { context.date.timeIntervalSince($0) } ?? .infinity
                let age = (relay.remote?.age ?? .infinity) + max(0, elapsed)
                let fresh = relay.remote?.fresh == true && age <= 30 && elapsed <= 30
                Text(fresh ? "Recent remote update" : "No fresh remote reading").font(.headline).foregroundStyle(fresh ? .green : .orange)
                if let snapshot = relay.remote?.snapshot {
                    HStack {
                        metric("Heart rate", fresh ? snapshot.heart_rate : nil, "bpm")
                        metric("Oxygen", fresh ? snapshot.oxygen : nil, "%")
                    }
                    Text("Recorded \(Date(timeIntervalSince1970: snapshot.captured).formatted(date: .abbreviated, time: .standard))").font(.caption.bold())
                    Text(snapshot.connection).font(.caption)
                    Text("Source: \(snapshot.source)").font(.caption)
                    if fresh && snapshot.alarm != "none" { Text(snapshot.alarm == "sensor" ? "Check sensor data" : "Shared monitor needs attention").foregroundStyle(.orange) }
                }
            }
            Button("Refresh now") { Task { await relay.fetchRemote() } }
            if let f = relay.families.first(where: { $0.id == relay.selected }), f.owner != relay.userID {
                Button("Leave this family", role: .destructive) { relay.perform { try await relay.leave() } }
            }
        }
    }
    private func metric(_ title: String, _ value: Double?, _ unit: String) -> some View {
        VStack(alignment: .leading) { Text(title).font(.caption); Text(value.map { String(format: "%.0f %@", $0, unit) } ?? "—").font(.title2.bold()) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
