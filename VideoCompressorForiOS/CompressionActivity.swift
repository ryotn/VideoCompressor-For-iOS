import ActivityKit

struct CompressionActivity: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var progress: Double
        var status: String
    }

    var sourceFileName: String
    var sourceFileSizeBytes: Int64
    var estimatedSizeBytes: Int64
}
