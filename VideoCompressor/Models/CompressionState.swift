import Foundation

enum CompressionState: Equatable {
    case idle
    case preparing
    case inProgress(progressPercent: Float, elapsedMs: Int64)
    case completed(outputPath: String, originalSizeBytes: Int64, outputSizeBytes: Int64)
    case failed(error: String)
    case cancelled

    var isActive: Bool {
        if case .preparing = self { return true }
        if case .inProgress = self { return true }
        return false
    }
}
