import AVFoundation

enum CompressionMode: String, CaseIterable, Identifiable {
    case simple = "簡単"
    case advanced = "詳細"

    var id: String { rawValue }
}

enum BitrateMode: String, CaseIterable, Identifiable {
    case percentage = "%指定"
    case direct = "直接指定"
    case preset = "プリセット"

    var id: String { rawValue }
}

enum ResolutionMode: String, CaseIterable, Identifiable {
    case percentage = "%指定"
    case direct = "直接指定"
    case preset = "プリセット"

    var id: String { rawValue }
}

enum FrameRateMode: String, CaseIterable, Identifiable {
    case percentage = "%指定"
    case direct = "直接指定"
    case preset = "プリセット"

    var id: String { rawValue }
}

enum BitratePreset: String, CaseIterable, Identifiable {
    case low = "低品質"
    case medium = "中品質"
    case high = "高品質"
    case veryHigh = "最高品質"

    var id: String { rawValue }

    var kbps: Int {
        switch self {
        case .low: 500
        case .medium: 1500
        case .high: 3000
        case .veryHigh: 6000
        }
    }
}

enum AudioBitratePreset: String, CaseIterable, Identifiable {
    case low = "低品質"
    case medium = "中品質"
    case high = "高品質"
    case veryHigh = "最高品質"

    var id: String { rawValue }

    var kbps: Int {
        switch self {
        case .low: 64
        case .medium: 128
        case .high: 192
        case .veryHigh: 256
        }
    }
}

enum ResolutionPreset: String, CaseIterable, Identifiable {
    case sd = "SD"
    case hd = "HD"
    case fhd = "FHD"
    case qhd = "QHD"

    var id: String { rawValue }

    var size: CGSize {
        switch self {
        case .sd: CGSize(width: 854, height: 480)
        case .hd: CGSize(width: 1280, height: 720)
        case .fhd: CGSize(width: 1920, height: 1080)
        case .qhd: CGSize(width: 2560, height: 1440)
        }
    }
}

enum FrameRatePreset: String, CaseIterable, Identifiable {
    case cinema = "24fps"
    case standard = "30fps"
    case smooth = "60fps"

    var id: String { rawValue }

    var fps: Int {
        switch self {
        case .cinema: 24
        case .standard: 30
        case .smooth: 60
        }
    }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case h265 = "H.265 (HEVC)"
    case av1 = "AV1"

    var id: String { rawValue }
}

struct VideoInfoSummary {
    let durationMs: Int
    let width: Int
    let height: Int
    let fileSizeBytes: Int64
    let bitrateBps: Int64
    let audioBitrateBps: Int64
    let frameRate: Float
}

struct SimpleCompressionOptions {
    let targetSizeMB: Int

    static func computeMaxSizeMB(videoInfo: VideoInfoSummary) -> Int {
        let sourceMB = Int(videoInfo.fileSizeBytes / (1024 * 1024))
        return max((sourceMB * 2) / 3, 10)
    }

    static func computeMinSizeMB(videoInfo: VideoInfoSummary) -> Int {
        guard videoInfo.durationMs > 0 else { return 1 }
        let durationSeconds = Double(videoInfo.durationMs) / 1000
        let minTotalKbps = 500 + 64
        let bytes = (Double(minTotalKbps) * 1000 * durationSeconds) / 8
        return max(Int(bytes / (1024 * 1024)), 1)
    }

    func computeAudioBitrateKbps(videoInfo: VideoInfoSummary?) -> Int {
        guard let videoInfo, videoInfo.durationMs > 0 else { return 64 }
        let targetBits = Double(targetSizeMB) * 1024 * 1024 * 8
        let durationSeconds = Double(videoInfo.durationMs) / 1000
        let totalKbps = Int(targetBits / durationSeconds / 1000)
        switch totalKbps {
        case 2500...: return 128
        case 1200...: return 96
        default: return 64
        }
    }

    func computeVideoBitrateKbps(videoInfo: VideoInfoSummary?) -> Int {
        guard let videoInfo, videoInfo.durationMs > 0 else { return 2000 }
        let targetBits = Double(targetSizeMB) * 1024 * 1024 * 8
        let durationSeconds = Double(videoInfo.durationMs) / 1000
        let totalKbps = Int(targetBits / durationSeconds / 1000)
        return max(totalKbps - computeAudioBitrateKbps(videoInfo: videoInfo), 500)
    }

    func computeResolutionPreset(videoBitrateKbps: Int) -> ResolutionPreset {
        videoBitrateKbps >= 2000 ? .fhd : .hd
    }

    func toCompressionOptions(videoInfo: VideoInfoSummary?, preferH265: Bool = true) -> CompressionOptions {
        let videoBitrate = computeVideoBitrateKbps(videoInfo: videoInfo)
        let audioBitrate = computeAudioBitrateKbps(videoInfo: videoInfo)
        return CompressionOptions(
            videoCodec: preferH265 ? .h265 : .h264,
            bitrateMode: .direct,
            bitrateDirectKbps: videoBitrate,
            audioBitrateMode: .direct,
            audioBitrateDirectKbps: audioBitrate,
            frameRateMode: .direct,
            frameRateDirectFps: 30,
            resolutionMode: .preset,
            resolutionPreset: computeResolutionPreset(videoBitrateKbps: videoBitrate)
        )
    }
}

struct CompressionOptions {
    let videoCodec: VideoCodec
    let bitrateMode: BitrateMode
    let bitratePercentage: Int
    let bitrateDirectKbps: Int
    let bitratePreset: BitratePreset
    let audioBitrateMode: BitrateMode
    let audioBitratePercentage: Int
    let audioBitrateDirectKbps: Int
    let audioBitratePreset: AudioBitratePreset
    let frameRateMode: FrameRateMode
    let frameRatePercentage: Int
    let frameRateDirectFps: Int
    let frameRatePreset: FrameRatePreset
    let resolutionMode: ResolutionMode
    let resolutionPercentage: Int
    let resolutionDirectWidth: Int
    let resolutionDirectHeight: Int
    let resolutionPreset: ResolutionPreset
    let removeAudio: Bool

    init(
        videoCodec: VideoCodec = .h264,
        bitrateMode: BitrateMode = .preset,
        bitratePercentage: Int = 50,
        bitrateDirectKbps: Int = 2000,
        bitratePreset: BitratePreset = .medium,
        audioBitrateMode: BitrateMode = .preset,
        audioBitratePercentage: Int = 100,
        audioBitrateDirectKbps: Int = 128,
        audioBitratePreset: AudioBitratePreset = .medium,
        frameRateMode: FrameRateMode = .preset,
        frameRatePercentage: Int = 100,
        frameRateDirectFps: Int = 30,
        frameRatePreset: FrameRatePreset = .standard,
        resolutionMode: ResolutionMode = .preset,
        resolutionPercentage: Int = 100,
        resolutionDirectWidth: Int = 1280,
        resolutionDirectHeight: Int = 720,
        resolutionPreset: ResolutionPreset = .hd,
        removeAudio: Bool = false
    ) {
        self.videoCodec = videoCodec
        self.bitrateMode = bitrateMode
        self.bitratePercentage = bitratePercentage
        self.bitrateDirectKbps = bitrateDirectKbps
        self.bitratePreset = bitratePreset
        self.audioBitrateMode = audioBitrateMode
        self.audioBitratePercentage = audioBitratePercentage
        self.audioBitrateDirectKbps = audioBitrateDirectKbps
        self.audioBitratePreset = audioBitratePreset
        self.frameRateMode = frameRateMode
        self.frameRatePercentage = frameRatePercentage
        self.frameRateDirectFps = frameRateDirectFps
        self.frameRatePreset = frameRatePreset
        self.resolutionMode = resolutionMode
        self.resolutionPercentage = resolutionPercentage
        self.resolutionDirectWidth = resolutionDirectWidth
        self.resolutionDirectHeight = resolutionDirectHeight
        self.resolutionPreset = resolutionPreset
        self.removeAudio = removeAudio
    }

    func computeEstimatedSizeBytes(videoInfo: VideoInfoSummary?) -> Int64 {
        guard let videoInfo, videoInfo.durationMs > 0 else { return 0 }
        let videoBitrateBps = computeTargetVideoBitrateBps(sourceBitrateBps: videoInfo.bitrateBps)
        let audioBitrateBps = removeAudio ? 0 : computeTargetAudioBitrateBps(sourceAudioBitrateBps: videoInfo.audioBitrateBps)
        let totalBitrate = videoBitrateBps + audioBitrateBps
        let seconds = Double(videoInfo.durationMs) / 1000
        return Int64((Double(totalBitrate) * seconds) / 8)
    }

    func computeTargetVideoBitrateBps(sourceBitrateBps: Int64) -> Int64 {
        switch bitrateMode {
        case .percentage:
            return Int64(Double(sourceBitrateBps) * Double(bitratePercentage) / 100)
        case .direct:
            return Int64(bitrateDirectKbps) * 1000
        case .preset:
            return Int64(bitratePreset.kbps) * 1000
        }
    }

    func computeTargetAudioBitrateBps(sourceAudioBitrateBps: Int64) -> Int64 {
        switch audioBitrateMode {
        case .percentage:
            return Int64(Double(sourceAudioBitrateBps) * Double(audioBitratePercentage) / 100)
        case .direct:
            return Int64(audioBitrateDirectKbps) * 1000
        case .preset:
            return Int64(audioBitratePreset.kbps) * 1000
        }
    }

    func computeTargetResolution(sourceWidth: Int, sourceHeight: Int) -> CGSize {
        switch resolutionMode {
        case .percentage:
            let width = max(Int(Double(sourceWidth) * Double(resolutionPercentage) / 100), 2)
            let height = max(Int(Double(sourceHeight) * Double(resolutionPercentage) / 100), 2)
            return CGSize(width: width, height: height)
        case .direct:
            return CGSize(width: max(resolutionDirectWidth, 2), height: max(resolutionDirectHeight, 2))
        case .preset:
            return resolutionPreset.size
        }
    }

    func computeTargetFrameRate(sourceFrameRate: Float) -> Int {
        let target: Int = switch frameRateMode {
        case .percentage:
            Int(Float(frameRatePercentage) * sourceFrameRate / 100)
        case .direct:
            frameRateDirectFps
        case .preset:
            frameRatePreset.fps
        }
        if sourceFrameRate > 0 {
            return max(min(target, Int(sourceFrameRate)), 1)
        }
        return max(target, 1)
    }
}

enum VideoCompressionError: LocalizedError {
    case noVideoTrack
    case exportSessionCreationFailed
    case exportFailed(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            "動画トラックを読み込めませんでした。"
        case .exportSessionCreationFailed:
            "圧縮セッションの作成に失敗しました。"
        case .exportFailed(let underlying):
            underlying?.localizedDescription ?? "圧縮処理に失敗しました。"
        }
    }
}

final class VideoCompressionService {
    func compress(inputURL: URL, options: CompressionOptions, progressHandler: @escaping (Float) -> Void) async throws -> URL {
        let sourceAsset = AVURLAsset(url: inputURL)
        _ = try await sourceAsset.load(.duration)
        let sourceTrack = try await sourceAsset.loadTracks(withMediaType: .video).first

        let assetForExport: AVAsset
        if options.removeAudio {
            assetForExport = try await composeVideoOnlyAsset(from: sourceAsset)
        } else {
            assetForExport = sourceAsset
        }

        let sourceSize: CGSize
        if let sourceTrack {
            sourceSize = try await loadDisplaySize(for: sourceTrack)
        } else {
            sourceSize = .zero
        }
        let presetName = exportPreset(for: options, sourceSize: sourceSize)

        guard let exportSession = AVAssetExportSession(asset: assetForExport, presetName: presetName) else {
            throw VideoCompressionError.exportSessionCreationFailed
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("compressed-\(UUID().uuidString)")
            .appendingPathExtension(options.videoCodec == .h265 ? "mov" : "mp4")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        exportSession.outputURL = outputURL
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.outputFileType = outputFileType(for: options, supportedFileTypes: exportSession.supportedFileTypes)

        let progressTask = Task {
            while !Task.isCancelled {
                progressHandler(exportSession.progress)
                try? await Task.sleep(for: .milliseconds(150))
            }
        }

        do {
            try await exportSession.exportAsync()
            progressTask.cancel()
            progressHandler(1.0)
            return outputURL
        } catch {
            progressTask.cancel()
            throw VideoCompressionError.exportFailed(underlying: error)
        }
    }

    private func exportPreset(for options: CompressionOptions, sourceSize: CGSize) -> String {
        if options.videoCodec == .h265,
           AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality) {
            return AVAssetExportPresetHEVCHighestQuality
        }

        let targetSize = options.computeTargetResolution(
            sourceWidth: Int(max(sourceSize.width, 0)),
            sourceHeight: Int(max(sourceSize.height, 0))
        )

        let longestEdge = max(targetSize.width, targetSize.height)
        switch longestEdge {
        case ..<640:
            return AVAssetExportPreset640x480
        case ..<960:
            return AVAssetExportPreset960x540
        case ..<1280:
            return AVAssetExportPreset1280x720
        case ..<1920:
            return AVAssetExportPreset1920x1080
        default:
            return AVAssetExportPresetHighestQuality
        }
    }

    private func outputFileType(for options: CompressionOptions, supportedFileTypes: [AVFileType]) -> AVFileType {
        let preferred: AVFileType = options.videoCodec == .h265 ? .mov : .mp4
        if supportedFileTypes.contains(preferred) {
            return preferred
        }
        if supportedFileTypes.contains(.mp4) {
            return .mp4
        }
        if supportedFileTypes.contains(.mov) {
            return .mov
        }
        return preferred
    }

    private func composeVideoOnlyAsset(from asset: AVAsset) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard
            let sourceVideoTrack = try await asset.loadTracks(withMediaType: .video).first,
            let destinationVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw VideoCompressionError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        try destinationVideoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceVideoTrack, at: .zero)
        destinationVideoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        return composition
    }

    private func loadDisplaySize(for track: AVAssetTrack) async throws -> CGSize {
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
    }
}

private extension AVAssetExportSession {
    func exportAsync() async throws {
        try await withCheckedThrowingContinuation { continuation in
            exportAsynchronously {
                switch self.status {
                case .completed:
                    continuation.resume(returning: ())
                case .failed, .cancelled:
                    continuation.resume(throwing: self.error ?? VideoCompressionError.exportFailed(underlying: nil))
                default:
                    continuation.resume(throwing: VideoCompressionError.exportFailed(underlying: self.error))
                }
            }
        }
    }
}
