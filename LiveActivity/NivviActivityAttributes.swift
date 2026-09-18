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
    }
    var title: String
}
