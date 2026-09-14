import Foundation

// Heart-rate freshness is independent of battery, oxygen and other BLE traffic.
struct HeartRateFreshness {
    static let timeout: TimeInterval = 30
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

enum HistoryMetric { case heartRate, oxygen
    func value(_ entry: SavedMeasurement) -> Int? { self == .heartRate ? entry.heartRate : entry.oxygen }
}
struct HistoryChartPoint: Identifiable {
    var id: UUID { entry.id }
    let entry: SavedMeasurement
    let value: Int
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
        return result.sorted { $0.entry.time < $1.entry.time }
    }
    static func nearest(_ entries: [SavedMeasurement], at date: Date, metric: HistoryMetric) -> SavedMeasurement? {
        entries.filter { metric.value($0) != nil && abs($0.time.timeIntervalSince(date)) <= 30 }
            .min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
    }
    static func window(day: Date, hours: Int, endingAt end: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let start = calendar.startOfDay(for: day)
        let finish = calendar.date(byAdding: .day, value: 1, to: start)!
        guard hours > 0 else { return start...finish }
        let duration = min(Double(hours) * 3600, finish.timeIntervalSince(start))
        let boundedEnd = min(finish, max(start.addingTimeInterval(duration), end))
        return boundedEnd.addingTimeInterval(-duration)...boundedEnd
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
    mutating func silence() { muted = active; active = nil }
    mutating func ingest(bpm: Int?, source: String, at now: Date, settings: AlarmSettings, allowExperimentalCustom: Bool = false) -> RateAlarm? {
        guard settings.validationMessage == nil, settings.highEnabled || settings.lowEnabled else { reset(); return nil }
        guard (source == "standard-2A37" || (allowExperimentalCustom && source == "experimental-custom")), let bpm = bpm, (1...299).contains(bpm) else { interrupt(); return nil }
        if let last = previous, now.timeIntervalSince(last) > 10 || now < last { interrupt() }
        previous = now
        let direction: RateAlarm?
        if settings.lowEnabled, let limit = settings.lowThreshold, bpm < limit { direction = .low }
        else if settings.highEnabled, let limit = settings.highThreshold, bpm > limit { direction = .high }
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
                    let row = "\(iso.string(from: entry.time)),\(entry.heartRate.map(String.init) ?? ""),\(entry.oxygen.map(String.init) ?? ""),\"\(escaped)\"\n"
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
            let hr = bucket.filter { $0.heartRate != nil }, oxygen = bucket.filter { $0.oxygen != nil }
            let chosen = [hr.min { $0.heartRate! < $1.heartRate! }, hr.max { $0.heartRate! < $1.heartRate! }, oxygen.min { $0.oxygen! < $1.oxygen! }, oxygen.max { $0.oxygen! < $1.oxygen! }].compactMap { $0 }
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
    mutating func didStore(source: String, at time: Date) { lastStored[source] = time }
    mutating func reset() { lastStored = [:] }
}

struct SavedEvent: Codable, Identifiable {
    var id = UUID()
    let time: Date
    let kind: String
    let title: String
    let detail: String
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
        try JSONEncoder().encode(entries).write(to: url(event.time), options: .atomic)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url(event.time).path)
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
