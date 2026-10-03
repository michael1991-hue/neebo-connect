import Foundation
import ActivityKit

struct NivviActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var heartRate: String
        var oxygen: String
        var connection: String
        var signal: String
        var nurseryHint: String
        var captured: TimeInterval = 0
        var measuredAt: TimeInterval = 0
        var seq: Int = 0
        var session: String = ""
        var stale: Bool = false
        var alarm: String = ""
        var sleep: String = ""

        init(heartRate: String, oxygen: String, connection: String, signal: String, nurseryHint: String, captured: TimeInterval = 0, measuredAt: TimeInterval = 0, seq: Int = 0, session: String = "", stale: Bool = false, alarm: String = "", sleep: String = "") {
            self.heartRate = heartRate
            self.oxygen = oxygen
            self.connection = connection
            self.signal = signal
            self.nurseryHint = nurseryHint
            self.captured = captured
            self.measuredAt = measuredAt
            self.seq = seq
            self.session = session
            self.stale = stale
            self.alarm = alarm
            self.sleep = sleep
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            heartRate = try values.decode(String.self, forKey: .heartRate)
            oxygen = try values.decode(String.self, forKey: .oxygen)
            connection = try values.decode(String.self, forKey: .connection)
            signal = try values.decode(String.self, forKey: .signal)
            nurseryHint = try values.decodeIfPresent(String.self, forKey: .nurseryHint) ?? ""
            captured = try values.decodeIfPresent(TimeInterval.self, forKey: .captured) ?? 0
            measuredAt = try values.decodeIfPresent(TimeInterval.self, forKey: .measuredAt) ?? 0
            seq = try values.decodeIfPresent(Int.self, forKey: .seq) ?? 0
            session = try values.decodeIfPresent(String.self, forKey: .session) ?? ""
            stale = try values.decodeIfPresent(Bool.self, forKey: .stale) ?? false
            alarm = try values.decodeIfPresent(String.self, forKey: .alarm) ?? ""
            sleep = try values.decodeIfPresent(String.self, forKey: .sleep) ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(heartRate, forKey: .heartRate)
            try values.encode(oxygen, forKey: .oxygen)
            try values.encode(connection, forKey: .connection)
            try values.encode(signal, forKey: .signal)
            try values.encode(nurseryHint, forKey: .nurseryHint)
            try values.encode(captured, forKey: .captured)
            try values.encode(measuredAt, forKey: .measuredAt)
            try values.encode(seq, forKey: .seq)
            try values.encode(session, forKey: .session)
            try values.encode(stale, forKey: .stale)
            try values.encode(alarm, forKey: .alarm)
            try values.encode(sleep, forKey: .sleep)
        }

        private enum CodingKeys: String, CodingKey {
            case heartRate, oxygen, connection, signal, nurseryHint, captured, measuredAt, seq, session, stale, alarm, sleep
        }
    }
    var title: String
}
