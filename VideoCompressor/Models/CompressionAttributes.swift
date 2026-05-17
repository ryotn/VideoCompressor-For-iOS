
import ActivityKit
import Foundation

struct CompressionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var progressPercent: Double
        var fileName: String
    }
    var totalSizeMb: Double?
}
