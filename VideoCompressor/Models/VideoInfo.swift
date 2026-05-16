import Foundation

struct VideoInfo: Equatable {
    let url: URL
    let displayName: String
    let sizeBytes: Int64
    let durationMs: Int64
    let width: Int
    let height: Int
    let bitrateBps: Int64
    let audioBitrateBps: Int64
    let frameRateFps: Float
    let videoCodecMime: String?
}
