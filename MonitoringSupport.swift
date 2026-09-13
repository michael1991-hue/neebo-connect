import Foundation

// Settings are deliberately unconfigured and off until the user enters their care-plan limits.
struct AlarmSettings: Codable, Equatable {
    var highEnabled = false
    var lowEnabled = false
    var highThreshold: Int?
    var lowThreshold: Int?
    var durationSeconds = 15
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
    mutating func ingest(bpm: Int?, source: String, at now: Date, settings: AlarmSettings) -> RateAlarm? {
        guard settings.validationMessage == nil, settings.highEnabled || settings.lowEnabled else { reset(); return nil }
        guard source == "standard-2A37", let bpm = bpm, (1...299).contains(bpm) else { interrupt(); return nil }
        if let last = previous, now.timeIntervalSince(last) > 10 || now < last { interrupt() }
        previous = now
        let direction: RateAlarm?
        if settings.lowEnabled, let limit = settings.lowThreshold, bpm <= limit { direction = .low }
        else if settings.highEnabled, let limit = settings.highThreshold, bpm >= limit { direction = .high }
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
        try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
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
