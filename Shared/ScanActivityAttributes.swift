import Foundation
import ActivityKit

struct ScanActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var count: Int
        var phase: String
        var totalDKK: Double
        var latestName: String
    }
    var title: String = "Kortscanner"
}
