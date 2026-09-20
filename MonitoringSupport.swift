import Foundation

enum NurseryPlace: String, Identifiable {
    case home, carer, exploring
    var id: String { rawValue }
    static var allCases: [NurseryPlace] { [.home, .carer] }
    var title: String {
        switch self {
        case .home: return "Home"
        case .carer, .exploring: return "With carer"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house.fill"
        case .carer, .exploring: return "heart.circle.fill"
        }
    }
    func banner(_ child: String) -> String {
        let name = child.isEmpty ? "They" : child
        switch self {
        case .home: return "\(name) is at home"
        case .carer, .exploring: return "\(name) is with a carer"
        }
    }
    func hint(_ child: String) -> String {
        let name = child.isEmpty ? "them" : child
        switch self {
        case .home: return "Leave a phone near \(name). Downstairs can follow on this Wi‑Fi."
        case .carer, .exploring: return "The carer’s iPhone stays with \(name). Family watch on theirs over the internet."
        }
    }
}

// Heart-rate freshness is independent of battery, oxygen and other BLE traffic.
struct HeartRateFreshness {
    static let timeout: TimeInterval = 120
    private(set) var lastValid: Date?
    private(set) var pausedSince: Date?
    func isExpired(at now: Date) -> Bool {
        guard let last = lastValid else { return false }
        return now.timeIntervalSince(last) > Self.timeout || now < last
    }
    mutating func pause() -> Bool {
        guard let last = lastValid, pausedSince == nil else { return false }
        pausedSince = last
        return true
    }
    // Returns the interval between usable readings, not a claimed disconnection duration.
    mutating func receive(at now: Date) -> TimeInterval? {
        let interval = pausedSince.map { max(0, now.timeIntervalSince($0)) }
        lastValid = now; pausedSince = nil
        return interval
    }
    mutating func reset() { self = Self() }
}

// BLE radio can drop for a second without a real measurement gap. Do not notify
// until the last usable heart rate is this old (or 45s after a disconnect with
// no reading yet).
enum ConnectionLossPolicy {
    static let silence: TimeInterval = 45
    static let minimumDelay: TimeInterval = 0.5
    static func notifyDelay(lastReading: Date?, now: Date) -> TimeInterval {
        let start = lastReading ?? now
        let elapsed = max(0, now.timeIntervalSince(start))
        return max(minimumDelay, silence - elapsed)
    }
    static func shouldNotify(lastReading: Date?, now: Date) -> Bool {
        guard let last = lastReading else { return true }
        return now.timeIntervalSince(last) >= silence || now < last
    }
}

enum FamilyLinkState: String {
    case idle, live, hostStale, sensorDisconnected, viewerOffline
}

struct FamilyLiveEvent: Equatable {
    var type: String
    var streamID: String
    var seq: Int
    var captured: Double
    var heartRate: Double?
    var heartRateAt: Double?
    var oxygen: Double?
    var oxygenAt: Double?
    var alarm: String
    var connection: String
    var serverReceived: Double?
}

enum FamilyLivePolicy {
    static let metricWindow: TimeInterval = 45
    static func accept(currentStream: String?, lastSeq: Int, incoming: FamilyLiveEvent) -> FamilyLiveEvent? {
        if incoming.type == "revoked" { return incoming }
        if incoming.seq < 1 { return nil }
        if incoming.streamID == currentStream && incoming.seq <= lastSeq { return nil }
        return incoming
    }
    static func metricFresh(at now: Date, stamped: Double?, hasValue: Bool) -> Bool {
        guard hasValue, let stamped else { return false }
        let age = now.timeIntervalSince1970 - stamped
        return age >= -5 && age <= metricWindow
    }
    static func link(following: Bool, socketConnected: Bool, lastEvent: Date?, hostConnection: String, heartFresh: Bool, sensorAlarm: Bool, now: Date) -> FamilyLinkState {
        guard following else { return .idle }
        if sensorAlarm || hostConnection == "idle" || hostConnection == "bluetoothOff" { return .sensorDisconnected }
        let eventAge = lastEvent.map { now.timeIntervalSince($0) } ?? .infinity
        if !socketConnected && eventAge > 12 { return .viewerOffline }
        if !heartFresh { return .hostStale }
        return .live
    }
    static func shouldSoundAlarm(catchup: Bool, previous: String, next: String) -> Bool {
        !catchup && previous != next && next != "none"
    }
    static func shouldSoundRecovery(catchup: Bool, previous: String, next: String, hasHeartRate: Bool) -> Bool {
        !catchup && hasHeartRate && previous != "none" && next == "none"
    }
    static func reconnectDelay(attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        return min(30, pow(2, Double(attempt - 2)))
    }
}

struct SharedAlertLog {
    static func event(previous: String, next: String, wasAcknowledged: Bool, acknowledged: Bool) -> (kind: String, title: String, detail: String)? {
        if previous == "none", next == "high" {
            return ("critical", "High heart-rate alert", "From the monitoring phone. Limits are set on that phone. Saved on this iPhone.")
        }
        if previous == "none", next == "low" {
            return ("critical", "Low heart-rate alert", "From the monitoring phone. Limits are set on that phone. Saved on this iPhone.")
        }
        if previous == "none", next == "sensor" {
            return ("measurement", "Check sensor data", "The monitoring phone reported no fresh heart-rate data. Saved on this iPhone.")
        }
        if (previous == "high" || previous == "low"), next == "none" {
            return ("critical", "Heart rate back to normal", "Reading on the monitoring phone returned within the configured limits. Saved on this iPhone.")
        }
        if !wasAcknowledged, acknowledged, next != "none" {
            return ("critical", "Alarm acknowledged", "Heard it was tapped. The alert on the monitoring phone stays active until a fresh in-range reading. Saved on this iPhone.")
        }
        return nil
    }
}

// Five minutes of unchanged received values is a heuristic, not proof of
// sensor failure. Rounding, averaging and cached reads can also repeat values.
struct StaleHeartRateDetector {
    static let duration: TimeInterval = 300
    // Permit 30-second device updates with delivery jitter. Longer gaps restart
    // the pending duration; absent packets cannot count as repeated readings.
    static let maximumGap: TimeInterval = 45
    private(set) var lastValue: Double?
    private(set) var lastTime: Date?
    private(set) var unchangedSince: Date?
    private(set) var isStale = false

    mutating func observe(_ value: Double, at time: Date) -> Bool {
        guard value.isFinite, value > 0 else { interrupt(); return false }
        if let lastTime, time <= lastTime {
            if time < lastTime { interrupt() }
            return false
        }
        if lastValue != value {
            isStale = false
            unchangedSince = time
        } else if let previous = lastTime,
                  time.timeIntervalSince(previous) > Self.maximumGap {
            unchangedSince = time
        }
        if unchangedSince == nil { unchangedSince = time }
        lastValue = value
        lastTime = time
        guard !isStale, let start = unchangedSince,
              time.timeIntervalSince(start) >= Self.duration else { return false }
        isStale = true
        return true
    }

    // Invalid/missing data interrupts the pending duration, never resolves an
    // already active warning. A changed valid value or session reset clears it.
    mutating func interrupt() { unchangedSince = nil; lastTime = nil }
    mutating func reset() { self = Self() }
}

struct WearableChargePolicy {
    private(set) var isCharging = false
    private var lastLevel: Int?
    mutating func observePowerState(charging: Bool) {
        isCharging = charging
    }
    mutating func observeLevel(_ percent: Int) {
        guard (0...100).contains(percent) else { return }
        if let last = lastLevel {
            if percent >= last + 8 { isCharging = true }
            if percent + 1 < last { isCharging = false }
        }
        lastLevel = percent
    }
    mutating func reset() { self = Self() }
}

enum NivviSiren: String, CaseIterable, Identifiable {
    case classic, urgent, pulse, deep, high
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "Classic"
        case .urgent: return "Urgent"
        case .pulse: return "Pulse"
        case .deep: return "Deep"
        case .high: return "High"
        }
    }
    var resource: String {
        switch self {
        case .classic: return "NivviSiren"
        case .urgent: return "NivviSirenUrgent"
        case .pulse: return "NivviSirenPulse"
        case .deep: return "NivviSirenDeep"
        case .high: return "NivviSirenHigh"
        }
    }
    var notificationFile: String { resource + ".wav" }
}

enum NivviRelief: String, CaseIterable, Identifiable {
    case soft, warm, bright, piano, hush
    var id: String { rawValue }
    var title: String {
        switch self {
        case .soft: return "Soft bells"
        case .warm: return "Warm"
        case .bright: return "Bright"
        case .piano: return "Piano"
        case .hush: return "Hush"
        }
    }
    var resource: String {
        switch self {
        case .soft: return "NivviRelief"
        case .warm: return "NivviReliefWarm"
        case .bright: return "NivviReliefBright"
        case .piano: return "NivviReliefPiano"
        case .hush: return "NivviReliefHush"
        }
    }
}

struct WearableBatteryPolicy {
    static let warn = 20
    static let urgent = 10
    static let clear = 25
    enum Level: Equatable { case ok, low, urgent }
    private(set) var level: Level = .ok
    mutating func observe(percent: Int, charging: Bool) -> Level? {
        guard (0...100).contains(percent) else { return nil }
        if charging || percent >= Self.clear {
            let changed = level != .ok
            level = .ok
            return changed ? .ok : nil
        }
        let next: Level = percent <= Self.urgent ? .urgent : (percent <= Self.warn ? .low : .ok)
        guard next != level else { return nil }
        level = next
        return next == .ok ? nil : next
    }
    mutating func reset() { self = Self() }
}

enum ProfileAvatarPolicy {
    static let symbols = [
        "star.fill", "heart.fill", "moon.stars.fill", "sparkles",
        "leaf.fill", "hare.fill", "tortoise.fill", "bird.fill",
        "fish.fill", "pawprint.fill", "cloud.fill", "sun.max.fill",
        "drop.fill", "flame.fill", "snowflake", "bolt.fill"
    ]
    static let colors = ["teal", "coral", "lavender", "mint", "navy", "peach"]
    static let defaultSymbol = "star.fill"
    static let defaultColor = "teal"
    static func allowed(symbol: String, color: String) -> Bool {
        symbols.contains(symbol) && colors.contains(color)
    }
}

enum BluetoothSignal {
    static func isUsable(_ rssi: Int) -> Bool { rssi != 127 && rssi < 0 }
    static func label(_ rssi: Int?) -> String {
        guard let rssi, isUsable(rssi) else { return "Unavailable" }
        if rssi >= -60 { return "Strong" }
        if rssi >= -75 { return "Good" }
        if rssi >= -85 { return "Fair" }
        return "Weak — keep the iPhone closer"
    }
    static func isWeak(_ rssi: Int?) -> Bool {
        guard let rssi, isUsable(rssi) else { return false }
        return rssi < -85
    }
}

enum HistoryMetric { case heartRate, oxygen
    func value(_ entry: SavedMeasurement) -> Double? {
        guard let value = self == .heartRate ? entry.heartRateValue : entry.oxygenValue, value.isFinite else { return nil }
        return value
    }
}
struct HistoryChartPoint: Identifiable {
    var id: UUID { entry.id }
    let entry: SavedMeasurement
    let value: Double
    let series: String
}
enum HistoryChartPolicy {
    // Historical snapshots are normally 30 seconds apart. Older records have no
    // continuity ID, so a saved interval over 60 seconds also breaks their line.
    static func points(_ entries: [SavedMeasurement], metric: HistoryMetric, maximum: Int = 600) -> [HistoryChartPoint] {
        var result: [HistoryChartPoint] = []
        for (source, values) in Dictionary(grouping: entries, by: { $0.source }) {
            var segment: [SavedMeasurement] = []
            var number = 0
            func flush() {
                guard let first = segment.first, let last = segment.last else { return }
                let budget = max(4, maximum * segment.count / max(1, entries.count))
                let reduced = [first] + DailyHistoryStore.chartSamples(segment, maximum: budget) + [last]
                var seen = Set<UUID>()
                for entry in reduced.sorted(by: { $0.time < $1.time }) where seen.insert(entry.id).inserted {
                    if let value = metric.value(entry) { result.append(HistoryChartPoint(entry: entry, value: value, series: "\(source)-\(number)")) }
                }
                segment = []; number += 1
            }
            for entry in values.sorted(by: { $0.time < $1.time }) {
                guard metric.value(entry) != nil else { flush(); continue }
                if let last = segment.last,
                   entry.time.timeIntervalSince(last.time) > 60 || last.continuityID != entry.continuityID { flush() }
                segment.append(entry)
            }
            flush()
        }
        var seen = Set<UUID>()
        return result
            .sorted { $0.entry.time < $1.entry.time }
            .filter { seen.insert($0.id).inserted }
    }
    static func nearest(_ entries: [SavedMeasurement], at date: Date, metric: HistoryMetric) -> SavedMeasurement? {
        entries.filter { metric.value($0) != nil && abs($0.time.timeIntervalSince(date)) <= 30 }
            .min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
    }
    static func window(day: Date, hours: Int, endingAt end: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        window(day: day, span: hours <= 0 ? 0 : TimeInterval(hours) * 3600, endingAt: end, calendar: calendar)
    }
    static func window(day: Date, span: TimeInterval, endingAt end: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let start = calendar.startOfDay(for: day)
        let finish = calendar.date(byAdding: .day, value: 1, to: start)!
        guard span > 0 else { return start...finish }
        let duration = min(span, finish.timeIntervalSince(start))
        let boundedEnd = min(finish, max(start.addingTimeInterval(duration), end))
        return boundedEnd.addingTimeInterval(-duration)...boundedEnd
    }
    static let zoomSpans: [TimeInterval] = [0, 6 * 3600, 3600, 900, 300]
    static func closerZoom(than span: TimeInterval) -> TimeInterval {
        zoomSpans.filter { $0 > 0 && (span <= 0 || $0 < span) }.max() ?? 300
    }
    static func widerZoom(than span: TimeInterval) -> TimeInterval {
        if span <= 0 { return 0 }
        let wider = zoomSpans.filter { $0 > span }
        return wider.min() ?? 0
    }
    static func yScale(values: [Double], floor: Double, ceiling: Double, pad: Double, fallback: Double) -> ClosedRange<Double> {
        let finite = values.filter(\.isFinite)
        let low = max(floor, (finite.min() ?? fallback) - pad)
        var high = min(ceiling, (finite.max() ?? (fallback + 20)) + pad)
        if !low.isFinite { return floor...(floor + 1) }
        if !high.isFinite || high <= low { high = low + 1 }
        return low...high
    }
    static func xScale(from: Date, to: Date, minimumSpan: TimeInterval = 1) -> ClosedRange<Date> {
        let start = min(from, to)
        var end = max(from, to)
        if end.timeIntervalSince(start) < minimumSpan { end = start.addingTimeInterval(minimumSpan) }
        return start...end
    }
}

extension SavedMeasurement {
    static func mapped(time: Date, heartRate: Double?, oxygen: Double?, source: String) -> SavedMeasurement {
        SavedMeasurement(
            id: stableID(time: time, source: source, heartRate: heartRate, oxygen: oxygen),
            time: time,
            heartRate: heartRate.map { Int($0.rounded()) },
            oxygen: oxygen.map { Int($0.rounded()) },
            source: source,
            exactHeartRate: heartRate,
            exactOxygen: oxygen
        )
    }
    static func stableID(time: Date, source: String, heartRate: Double?, oxygen: Double?) -> UUID {
        let millis = UInt64(bitPattern: Int64((time.timeIntervalSince1970 * 1000).rounded()))
        var sourceHash: UInt64 = 5381
        for byte in source.utf8 { sourceHash = (sourceHash &* 33) &+ UInt64(byte) }
        let hrBits = heartRate?.bitPattern ?? 0
        let o2Bits = oxygen?.bitPattern ?? 0
        let a = millis ^ sourceHash
        let b = hrBits ^ o2Bits &* 16777619
        return UUID(uuid: (
            UInt8(truncatingIfNeeded: a >> 56),
            UInt8(truncatingIfNeeded: a >> 48),
            UInt8(truncatingIfNeeded: a >> 40),
            UInt8(truncatingIfNeeded: a >> 32),
            UInt8(truncatingIfNeeded: a >> 24),
            UInt8(truncatingIfNeeded: a >> 16),
            UInt8((UInt8(truncatingIfNeeded: a >> 8) & 0x0f) | 0x40),
            UInt8(truncatingIfNeeded: a),
            UInt8((UInt8(truncatingIfNeeded: b >> 56) & 0x3f) | 0x80),
            UInt8(truncatingIfNeeded: b >> 48),
            UInt8(truncatingIfNeeded: b >> 40),
            UInt8(truncatingIfNeeded: b >> 32),
            UInt8(truncatingIfNeeded: b >> 24),
            UInt8(truncatingIfNeeded: b >> 16),
            UInt8(truncatingIfNeeded: b >> 8),
            UInt8(truncatingIfNeeded: b)
        ))
    }
    static func uniquelyIdentified(_ entries: [SavedMeasurement]) -> [SavedMeasurement] {
        var seen = Set<UUID>()
        return entries.filter { $0.time.timeIntervalSince1970.isFinite && seen.insert($0.id).inserted }
    }
}

// Settings are deliberately unconfigured and off until the user enters their care-plan limits.
struct AlarmSettings: Codable, Equatable {
    var highEnabled = false
    var lowEnabled = false
    var highThreshold: Int?
    var lowThreshold: Int?
    var durationSeconds = 15
    var experimentalCustomEnabled = false
    enum CodingKeys: String, CodingKey { case highEnabled, lowEnabled, highThreshold, lowThreshold, durationSeconds, experimentalCustomEnabled }
    init(highEnabled: Bool = false, lowEnabled: Bool = false, highThreshold: Int? = nil, lowThreshold: Int? = nil, durationSeconds: Int = 15, experimentalCustomEnabled: Bool = false) {
        self.highEnabled = highEnabled; self.lowEnabled = lowEnabled
        self.highThreshold = highThreshold; self.lowThreshold = lowThreshold
        self.durationSeconds = durationSeconds; self.experimentalCustomEnabled = experimentalCustomEnabled
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        highEnabled = try values.decodeIfPresent(Bool.self, forKey: .highEnabled) ?? false
        lowEnabled = try values.decodeIfPresent(Bool.self, forKey: .lowEnabled) ?? false
        highThreshold = try values.decodeIfPresent(Int.self, forKey: .highThreshold)
        lowThreshold = try values.decodeIfPresent(Int.self, forKey: .lowThreshold)
        durationSeconds = try values.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 15
        experimentalCustomEnabled = try values.decodeIfPresent(Bool.self, forKey: .experimentalCustomEnabled) ?? false
    }
    var validationMessage: String? {
        if highEnabled && !(1...299).contains(highThreshold ?? 0) { return "Enter your high limit before enabling high alerts." }
        if lowEnabled && !(1...299).contains(lowThreshold ?? 0) { return "Enter your low limit before enabling low alerts." }
        if highEnabled && lowEnabled, let low = lowThreshold, let high = highThreshold, low >= high { return "The low limit must be below the high limit." }
        if !(5...120).contains(durationSeconds) { return "Choose a duration from 5 to 120 seconds." }
        return nil
    }
}
enum RateAlarm: String { case low, high
    var title: String { self == .low ? "Low heart-rate alert" : "High heart-rate alert" }
}
struct RateAlarmEngine {
    private(set) var active: RateAlarm?
    private var pending: RateAlarm?
    private var since: Date?
    private var previous: Date?
    private var muted: RateAlarm?
    // Unknown or stale data interrupts the dwell period; it cannot declare an alarm resolved.
    mutating func interrupt() { pending = nil; since = nil; previous = nil }
    mutating func reset() { self = Self() }
    // Acknowledgement silences the current alarm without declaring the reading
    // safe. The active excursion remains visible until a fresh in-range sample
    // causes ingestExact() to reset it.
    mutating func silence() { if let active { muted = active } }
    mutating func ingest(bpm: Int?, source: String, at now: Date, settings: AlarmSettings, allowExperimentalCustom: Bool = false) -> RateAlarm? {
        ingestExact(bpm: bpm.map(Double.init), source: source, at: now, settings: settings, allowExperimentalCustom: allowExperimentalCustom)
    }
    mutating func ingestExact(bpm: Double?, source: String, at now: Date, settings: AlarmSettings, allowExperimentalCustom: Bool = false) -> RateAlarm? {
        guard settings.validationMessage == nil, settings.highEnabled || settings.lowEnabled else { reset(); return nil }
        guard (source == "standard-2A37" || source == "standard-PLX-continuous" || (allowExperimentalCustom && source == "experimental-custom")), let bpm = bpm, bpm.isFinite, bpm > 0, bpm <= 65535 else { interrupt(); return nil }
        if let last = previous, now.timeIntervalSince(last) > 10 || now < last { interrupt() }
        previous = now
        let direction: RateAlarm?
        if settings.lowEnabled, let limit = settings.lowThreshold, bpm < Double(limit) { direction = .low }
        else if settings.highEnabled, let limit = settings.highThreshold, bpm > Double(limit) { direction = .high }
        else { direction = nil }
        guard let direction = direction else { reset(); return nil }
        if muted != direction { muted = nil }
        if pending != direction { pending = direction; since = now }
        guard muted != direction, active != direction, let start = since,
              now.timeIntervalSince(start) >= Double(settings.durationSeconds) else { return nil }
        active = direction
        return direction
    }
}

struct SessionIntent {
    var deviceID: UUID?
    var enabled = false
    func shouldReconnect(_ identifier: UUID) -> Bool { enabled && deviceID == identifier }
    mutating func start(_ identifier: UUID) { deviceID = identifier; enabled = true }
    mutating func stop() { enabled = false }
}

// One append-only file per calendar day avoids rewriting weeks of data for every packet.
// The last 30 calendar days are retained; an existing v0.2 file is migrated atomically.
final class DailyHistoryStore {
    let directory: URL
    let calendar: Calendar
    private let fm = FileManager.default
    private let formatter: DateFormatter
    private var lastPrunedDay: String?
    init(folder: URL, calendar: Calendar = .current) {
        self.directory = folder.appendingPathComponent("MeasurementHistory", isDirectory: true)
        self.calendar = calendar
        formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
    }
    func key(_ date: Date) -> String { formatter.string(from: date) }
    private func files() throws -> [URL] {
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" && formatter.date(from: $0.deletingPathExtension().lastPathComponent) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func prepare(legacy: URL, now: Date = Date()) throws {
        if !fm.fileExists(atPath: directory.path) {
            let staging = directory.appendingPathExtension("migration")
            // Only our incomplete staging directory is replaced. Source history stays intact.
            if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            if fm.fileExists(atPath: legacy.path) {
                let old = try JSONDecoder().decode([SavedMeasurement].self, from: Data(contentsOf: legacy))
                for (day, entries) in Dictionary(grouping: old, by: { key($0.time) }) {
                    var data = Data()
                    for entry in entries { data.append(try JSONEncoder().encode(entry)); data.append(10) }
                    try data.write(to: staging.appendingPathComponent(day + ".jsonl"), options: .atomic)
                }
            }
            try fm.moveItem(at: staging, to: directory)
        }
        try prune(now: now)
    }
    func days() throws -> [Date] {
        try files().compactMap { formatter.date(from: $0.deletingPathExtension().lastPathComponent) }.reversed()
    }
    func load(day: Date) throws -> [SavedMeasurement] {
        let url = directory.appendingPathComponent(key(day) + ".jsonl")
        guard fm.fileExists(atPath: url.path) else { return [] }
        // A damaged row is reported to the caller; the file is never silently rewritten.
        return try Data(contentsOf: url).split(separator: 10).map { try JSONDecoder().decode(SavedMeasurement.self, from: Data($0)) }
    }
    func append(_ entry: SavedMeasurement, now: Date = Date()) throws {
        if lastPrunedDay != key(now) { try prune(now: now) }
        let url = directory.appendingPathComponent(key(entry.time) + ".jsonl")
        var data = try JSONEncoder().encode(entry); data.append(10)
        if !fm.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        else {
            let handle = try FileHandle(forUpdating: url)
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                let lastByte = try handle.read(upToCount: 1)
                // Refuse to append to a torn last row. Preserve the complete file for recovery.
                guard lastByte == Data([10]) else { throw CocoaError(.fileReadCorruptFile) }
            }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        }
        // BLE callbacks may run while the phone is locked, after its first unlock.
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
    func prune(now: Date) throws {
        let cutoff = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!
        for url in try files() where url.deletingPathExtension().lastPathComponent < key(cutoff) { try fm.removeItem(at: url) }
        lastPrunedDay = key(now)
    }
    func clear(legacy: URL) throws {
        for url in try files() { try fm.removeItem(at: url) }
        if fm.fileExists(atPath: legacy.path) { try fm.removeItem(at: legacy) }
    }
    func export(to url: URL) throws {
        let temporary = url.appendingPathExtension("tmp")
        try Data("time,heart_rate_bpm,oxygen_percent,source\n".utf8).write(to: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.seekToEnd()
            let iso = ISO8601DateFormatter()
            for day in try days().reversed() {
                for entry in try load(day: day) {
                    let escaped = entry.source.replacingOccurrences(of: "\"", with: "\"\"")
                    let heartRate = entry.exactHeartRate.map(MetricText.number) ?? entry.heartRate.map(String.init) ?? ""
                    let oxygen = entry.exactOxygen.map(MetricText.number) ?? entry.oxygen.map(String.init) ?? ""
                    let row = "\(iso.string(from: entry.time)),\(heartRate),\(oxygen),\"\(escaped)\"\n"
                    try handle.write(contentsOf: Data(row.utf8))
                }
            }
            try handle.close()
            if fm.fileExists(atPath: url.path) { _ = try fm.replaceItemAt(url, withItemAt: temporary) }
            else { try fm.moveItem(at: temporary, to: url) }
        } catch { try? handle.close(); try? fm.removeItem(at: temporary); throw error }
    }
    // Keep chronological bucket extrema, so isolated lows/highs remain visible in long charts.
    static func chartSamples(_ entries: [SavedMeasurement], maximum: Int = 600) -> [SavedMeasurement] {
        guard entries.count > maximum else { return entries }
        let bucketSize = max(1, Int(ceil(Double(entries.count) / Double(max(1, maximum / 4)))))
        var result: [SavedMeasurement] = []
        for offset in stride(from: 0, to: entries.count, by: bucketSize) {
            let bucket = Array(entries[offset..<min(offset + bucketSize, entries.count)])
            let hr = bucket.filter { ($0.heartRateValue ?? .nan).isFinite }
            let oxygen = bucket.filter { ($0.oxygenValue ?? .nan).isFinite }
            let chosen = [
                hr.min { ($0.heartRateValue ?? 0) < ($1.heartRateValue ?? 0) },
                hr.max { ($0.heartRateValue ?? 0) < ($1.heartRateValue ?? 0) },
                oxygen.min { ($0.oxygenValue ?? 0) < ($1.oxygenValue ?? 0) },
                oxygen.max { ($0.oxygenValue ?? 0) < ($1.oxygenValue ?? 0) }
            ].compactMap { $0 }
            var seen = Set<UUID>()
            result.append(contentsOf: chosen.sorted { $0.time < $1.time }.filter { seen.insert($0.id).inserted })
        }
        return result
    }
}

struct MeasurementSamplingPolicy {
    private var lastStored: [String: Date] = [:]
    func shouldStore(source: String, at time: Date) -> Bool {
        guard let last = lastStored[source] else { return true }
        return time < last || time.timeIntervalSince(last) >= 30
    }
    // Shared catch-up points are in the past; never treat an older packet as a clock rollback.
    func shouldStoreNewer(source: String, at time: Date) -> Bool {
        guard let last = lastStored[source] else { return true }
        return time.timeIntervalSince(last) >= 30
    }
    mutating func didStore(source: String, at time: Date) { lastStored[source] = time }
    mutating func reset() { lastStored = [:] }
    mutating func reset(source: String) { lastStored[source] = nil }
}

enum SharedHistoryPolicy {
    static let cadence: TimeInterval = 30
    static func bucket(_ time: Date) -> Date {
        Date(timeIntervalSince1970: (time.timeIntervalSince1970 / cadence).rounded(.towardZero) * cadence)
    }
    static func slot(source: String, time: Date) -> UUID {
        SavedMeasurement.stableID(time: bucket(time), source: source + ".slot", heartRate: nil, oxygen: nil)
    }
}

enum WiFiSharePolicy {
    static let packetStale: TimeInterval = 6
    static let connectGiveUp: TimeInterval = 5
    static let tcpPort: UInt16 = 19891
    static func shouldDrop(now: Date, lastPacket: Date?, connectedAt: Date?) -> Bool {
        if let lastPacket { return now.timeIntervalSince(lastPacket) >= packetStale }
        if let connectedAt { return now.timeIntervalSince(connectedAt) >= connectGiveUp }
        return false
    }
    static func reconnectDelay(attempt: Int) -> TimeInterval {
        min(8, pow(2, Double(max(0, attempt - 1))) * 0.5)
    }
}

struct SavedEvent: Codable, Identifiable {
    var id = UUID()
    let time: Date
    let kind: String
    var title: String
    var detail: String
    let heartRate: Int?
}
final class EventHistoryStore {
    let directory: URL
    private let calendar: Calendar
    private let formatter: DateFormatter
    private let fm = FileManager.default
    init(folder: URL, calendar: Calendar = .current) {
        directory = folder.appendingPathComponent("EventHistory", isDirectory: true)
        self.calendar = calendar
        formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
    }
    private func url(_ day: Date) -> URL { directory.appendingPathComponent(formatter.string(from: day) + ".json") }
    func prepare(now: Date = Date()) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let cutoff = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))!
        for day in try days() where day < cutoff { try fm.removeItem(at: url(day)) }
    }
    func days() throws -> [Date] {
        guard fm.fileExists(atPath: directory.path) else { return [] }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { formatter.date(from: $0.deletingPathExtension().lastPathComponent) }.sorted(by: >)
    }
    func load(day: Date) throws -> [SavedEvent] {
        guard fm.fileExists(atPath: url(day).path) else { return [] }
        return try JSONDecoder().decode([SavedEvent].self, from: Data(contentsOf: url(day)))
    }
    func append(_ event: SavedEvent) throws {
        try prepare(now: event.time)
        var entries = try load(day: event.time)
        entries.append(event)
        try write(entries, day: event.time)
    }
    func replace(_ event: SavedEvent) throws {
        var entries = try load(day: event.time)
        guard let index = entries.firstIndex(where: { $0.id == event.id }) else { return }
        entries[index] = event
        try write(entries, day: event.time)
    }
    func delete(_ event: SavedEvent) throws {
        var entries = try load(day: event.time)
        entries.removeAll { $0.id == event.id }
        if entries.isEmpty {
            let file = url(event.time)
            if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
        } else {
            try write(entries, day: event.time)
        }
    }
    private func write(_ entries: [SavedEvent], day: Date) throws {
        try JSONEncoder().encode(entries).write(to: url(day), options: .atomic)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url(day).path)
        #endif
    }
    func clear() throws { for day in try days() { try fm.removeItem(at: url(day)) } }
    func export(to destination: URL) throws {
        let iso = ISO8601DateFormatter()
        func csv(_ value: String) -> String {
            // Neutralise spreadsheet formulas in parent-entered notes before quoting.
            let safe = value.first.map { "=+-@\t\r".contains($0) } == true ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var output = "time,kind,event,detail,heart_rate_bpm\n"
        for day in try days().reversed() {
            for event in try load(day: day) {
                output += [iso.string(from: event.time), csv(event.kind), csv(event.title), csv(event.detail), event.heartRate.map(String.init) ?? ""].joined(separator: ",") + "\n"
            }
        }
        try output.write(to: destination, atomically: true, encoding: .utf8)
    }
}


// A single fallback read may follow a real BLE event, but reads never create
// their own event loop. Both recent data and recent attempts throttle polling.
struct MeasurementTransportPolicy {
    static let interval: TimeInterval = 5
    private(set) var lastAttempt: Date?
    func shouldRead(at now: Date, lastMeasurement: Date?) -> Bool {
        for time in [lastAttempt, lastMeasurement].compactMap({ $0 }) {
            if (0..<Self.interval).contains(now.timeIntervalSince(time)) { return false }
        }
        return true
    }
    mutating func didRequest(at now: Date) { lastAttempt = now }
    mutating func reset() { lastAttempt = nil }
}

// Refresh the system-scheduled advisory without postponing it on unrelated data.
// A newly received measurement must replace an imminent stale-data warning.
struct BackgroundDataReminderPolicy {
    private(set) var scheduledAt: Date?
    private(set) var deadline: Date?
    mutating func delay(at now: Date, lastMeasurement: Date?) -> TimeInterval? {
        if let scheduledAt, let deadline,
           (0..<5).contains(now.timeIntervalSince(scheduledAt)),
           deadline.timeIntervalSince(now) > 30 { return nil }
        let age = max(0, now.timeIntervalSince(lastMeasurement ?? now))
        let delay = max(1, 40 - age)
        scheduledAt = now; deadline = now.addingTimeInterval(delay)
        return delay
    }
    mutating func reset() { self = Self() }
}
