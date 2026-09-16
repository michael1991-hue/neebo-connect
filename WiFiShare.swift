import Foundation
import Network
import Combine

struct WiFiSnapshot: Codable, Equatable {
    var pin: String
    var heartRate: String
    var oxygen: String
    var connection: String
    var captured: TimeInterval
    var alarm: String?
    var charging: Bool?
    var battery: String?
}

@MainActor
final class WiFiRelay: ObservableObject {
    static let shared = WiFiRelay()
    private static let type = "_nivvi-share._tcp"
    @Published var hosting = false
    @Published var following = false
    @Published var pin: String
    @Published var joinPin = ""
    @Published var playAlerts = true
    @Published var status = "Off"
    @Published var latest: WiFiSnapshot?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var hosts: [NWConnection] = []
    private var viewer: NWConnection?
    private var payload = Data()
    private var buffer = Data()

    init() {
        if let saved = UserDefaults.standard.string(forKey: "nivvi.wifi.pin"), saved.count == 4 {
            pin = saved
        } else {
            pin = String(format: "%04d", Int.random(in: 1000...9999))
            UserDefaults.standard.set(pin, forKey: "nivvi.wifi.pin")
        }
    }

    var remoteFresh: Bool {
        guard following, let latest else { return false }
        return Date().timeIntervalSince1970 - latest.captured < 20
    }

    func publish(heartRate: String, oxygen: String, connection: String, alarm: String = "none", charging: Bool = false, battery: String = "—") {
        let snap = WiFiSnapshot(pin: pin, heartRate: heartRate, oxygen: oxygen, connection: connection, captured: Date().timeIntervalSince1970, alarm: alarm, charging: charging, battery: battery)
        payload = (try? JSONEncoder().encode(snap)) ?? Data()
        payload.append(10)
        guard hosting else { return }
        for connection in hosts { connection.send(content: payload, completion: .contentProcessed { _ in }) }
    }

    func setHosting(_ on: Bool) {
        if on { startHost() } else { stopHost() }
    }

    func setJoinPin(_ value: String) {
        joinPin = String(value.filter(\.isNumber).prefix(4))
    }

    func setFollowing(_ on: Bool) {
        if on {
            guard joinPin.count == 4 else {
                status = "Type the 4-digit code from the nursery iPhone first."
                following = false
                return
            }
            startViewer()
        } else {
            stopViewer()
        }
    }

    private func startHost() {
        stopViewer()
        stopHost()
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: "Nivvi", type: Self.type)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready: self?.hosting = true; self?.status = "Sharing on this Wi‑Fi · code \(self?.pin ?? "")"
                    case .failed(let error): self?.status = error.localizedDescription; self?.stopHost()
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.attachHost(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
            status = "Starting Wi‑Fi share…"
        } catch {
            status = error.localizedDescription
        }
    }

    private func attachHost(_ connection: NWConnection) {
        hosts.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed = state { self?.hosts.removeAll { $0 === connection } }
                if case .cancelled = state { self?.hosts.removeAll { $0 === connection } }
            }
        }
        connection.start(queue: .main)
        if !payload.isEmpty {
            connection.send(content: payload, completion: .contentProcessed { _ in })
        }
    }

    private func stopHost() {
        listener?.cancel(); listener = nil
        hosts.forEach { $0.cancel() }; hosts = []
        if hosting { hosting = false }
        if !following { status = "Off" }
    }

    private func startViewer() {
        stopHost()
        stopViewer()
        following = true
        latest = nil
        status = "Looking for the nursery iPhone on this Wi‑Fi…"
        let browser = NWBrowser(for: .bonjour(type: Self.type, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed(let error) = state {
                    self?.status = error.localizedDescription
                    self?.stopViewer()
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.viewer == nil, let first = results.first else { return }
                self.connect(first.endpoint)
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func connect(_ endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        viewer = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state { self?.status = "Linked on this Wi‑Fi" }
                if case .failed(let error) = state {
                    self?.status = error.localizedDescription
                    self?.viewer = nil
                }
            }
        }
        receive(connection)
        connection.start(queue: .main)
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    while let newline = self.buffer.firstIndex(of: 10) {
                        let line = self.buffer.subdata(in: 0..<newline)
                        if newline + 1 < self.buffer.count {
                            self.buffer = self.buffer.subdata(in: (newline + 1)..<self.buffer.count)
                        } else {
                            self.buffer = Data()
                        }
                        if let snap = try? JSONDecoder().decode(WiFiSnapshot.self, from: line), snap.pin == self.joinPin {
                            self.latest = snap
                            self.status = "Linked on this Wi‑Fi"
                        } else if let snap = try? JSONDecoder().decode(WiFiSnapshot.self, from: line), snap.pin != self.joinPin {
                            self.status = "Wrong share code. Match the nursery iPhone."
                        }
                    }
                }
                if isComplete || error != nil {
                    self.viewer = nil
                    if self.following { self.status = "Lost the nursery iPhone. Stay on the same Wi‑Fi." }
                    return
                }
                self.receive(connection)
            }
        }
    }

    private func stopViewer() {
        browser?.cancel(); browser = nil
        viewer?.cancel(); viewer = nil
        buffer = Data()
        latest = nil
        if following { following = false }
        if !hosting { status = "Off" }
    }
}
