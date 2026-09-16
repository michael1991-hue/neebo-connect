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
    private var wantHost = false
    private var wantFollow = false
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var hosts: [NWConnection] = []
    private var viewer: NWConnection?
    private var payload = Data()
    private var buffer = Data()
    private var keepAlive: Timer?
    private var knownEndpoint: NWEndpoint?
    private var lastHR = "No reading"
    private var lastO2 = "No reading"
    private var lastConnection = "Off"
    private var lastAlarm = "none"
    private var lastCharging = false
    private var lastBattery = "—"

    init() {
        if let saved = UserDefaults.standard.string(forKey: "nivvi.wifi.pin"), saved.count == 4 {
            pin = saved
        } else {
            pin = String(format: "%04d", Int.random(in: 1000...9999))
            UserDefaults.standard.set(pin, forKey: "nivvi.wifi.pin")
        }
        keepAlive = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let timer = keepAlive { RunLoop.main.add(timer, forMode: .common) }
    }

    var remoteFresh: Bool {
        guard following, let latest else { return false }
        return Date().timeIntervalSince1970 - latest.captured < 45
    }

    func publish(heartRate: String, oxygen: String, connection: String, alarm: String = "none", charging: Bool = false, battery: String = "—") {
        lastHR = heartRate
        lastO2 = oxygen
        lastConnection = connection
        lastAlarm = alarm
        lastCharging = charging
        lastBattery = battery
        emit()
    }

    private func emit() {
        let snap = WiFiSnapshot(pin: pin, heartRate: lastHR, oxygen: lastO2, connection: lastConnection, captured: Date().timeIntervalSince1970, alarm: lastAlarm, charging: lastCharging, battery: lastBattery)
        payload = (try? JSONEncoder().encode(snap)) ?? Data()
        payload.append(10)
        flush()
    }

    func setHosting(_ on: Bool) {
        wantHost = on
        if on { wantFollow = false; startHost() } else { stopHost() }
    }

    func setJoinPin(_ value: String) {
        joinPin = String(value.filter(\.isNumber).prefix(4))
    }

    func setFollowing(_ on: Bool) {
        wantFollow = on
        if on {
            guard joinPin.count == 4 else {
                status = "Type the 4-digit code from the nursery iPhone first."
                following = false
                wantFollow = false
                return
            }
            wantHost = false
            startViewer()
        } else {
            stopViewer()
        }
    }

    func revive() {
        if wantHost { if listener == nil { startHost() } else { flush() } }
        if wantFollow, viewer == nil { startViewer() }
    }

    private func tick() {
        if wantHost {
            emit()
            if listener == nil { startHost() }
        }
        if wantFollow {
            following = true
            if viewer == nil { reconnectViewer() }
        }
    }

    private func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 5
            tcp.keepaliveInterval = 5
            tcp.noDelay = true
        }
        return parameters
    }

    private func flush() {
        guard wantHost, !payload.isEmpty else { return }
        for connection in hosts {
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                if error != nil {
                    Task { @MainActor in self?.hosts.removeAll { $0 === connection } }
                }
            })
        }
    }

    private func startHost() {
        stopViewer()
        stopHost(clearWant: false)
        do {
            let listener = try NWListener(using: parameters())
            listener.service = NWListener.Service(name: "Nivvi", type: Self.type)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.hosting = true
                        self?.status = "Sharing on this Wi‑Fi · code \(self?.pin ?? "")"
                    case .failed(let error):
                        self?.status = error.localizedDescription
                        self?.listener?.cancel()
                        self?.listener = nil
                        self?.hosting = false
                    case .cancelled:
                        self?.hosting = false
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.attachHost(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
            hosting = true
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
                if case .ready = state { self?.flush() }
            }
        }
        connection.start(queue: .main)
        flush()
    }

    private func stopHost(clearWant: Bool = true) {
        if clearWant { wantHost = false }
        listener?.cancel(); listener = nil
        hosts.forEach { $0.cancel() }; hosts = []
        if hosting { hosting = false }
        if !wantFollow { status = "Off" }
    }

    private func startViewer() {
        stopHost()
        following = true
        status = "Looking for the nursery iPhone on this Wi‑Fi…"
        if browser == nil {
            let browser = NWBrowser(for: .bonjour(type: Self.type, domain: nil), using: parameters())
            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    if case .failed(let error) = state {
                        self?.status = error.localizedDescription
                        self?.browser?.cancel()
                        self?.browser = nil
                    }
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in
                    guard let self, self.wantFollow else { return }
                    if let first = results.first { self.knownEndpoint = first.endpoint }
                    if self.viewer == nil, let first = results.first {
                        self.connect(first.endpoint)
                    }
                }
            }
            browser.start(queue: .main)
            self.browser = browser
        }
        reconnectViewer()
    }

    private func reconnectViewer() {
        guard wantFollow, viewer == nil else { return }
        if let knownEndpoint { connect(knownEndpoint) }
    }

    private func connect(_ endpoint: NWEndpoint) {
        viewer?.cancel()
        buffer = Data()
        let connection = NWConnection(to: endpoint, using: parameters())
        viewer = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .ready = state { self.status = "Linked on this Wi‑Fi" }
                if case .failed(let error) = state {
                    self.status = "Lost the nursery iPhone. Reconnecting…"
                    if self.viewer === connection { self.viewer = nil }
                    _ = error
                }
                if case .cancelled = state, self.viewer === connection {
                    self.viewer = nil
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
                    if self.viewer === connection {
                        self.viewer = nil
                        if self.wantFollow { self.status = "Lost the nursery iPhone. Reconnecting…" }
                    }
                    return
                }
                self.receive(connection)
            }
        }
    }

    private func stopViewer() {
        wantFollow = false
        browser?.cancel(); browser = nil
        viewer?.cancel(); viewer = nil
        knownEndpoint = nil
        buffer = Data()
        latest = nil
        if following { following = false }
        if !wantHost { status = "Off" }
    }
}
