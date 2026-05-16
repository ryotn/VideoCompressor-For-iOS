import Foundation

enum BitrateMode: String, CaseIterable, Identifiable, Codable {
    case percentage = "Percentage"
    case direct = "Direct"
    case preset = "Preset"
    var id: String { rawValue }
}

enum ResolutionMode: String, CaseIterable, Identifiable, Codable {
    case percentage = "Percentage"
    case direct = "Direct"
    case preset = "Preset"
    var id: String { rawValue }
}

enum FrameRateMode: String, CaseIterable, Identifiable, Codable {
    case percentage = "Percentage"
    case direct = "Direct"
    case preset = "Preset"
    var id: String { rawValue }
}

enum CompressionMode: String, CaseIterable, Identifiable, Codable {
    case simple = "Simple"
    case advanced = "Advanced"
    var id: String { rawValue }
}

enum BitratePreset: Int, CaseIterable, Identifiable, Codable {
    case low = 500
    case medium = 1500
    case high = 3000
    case veryHigh = 6000

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .low: return "Low (500 kbps)"
        case .medium: return "Medium (1.5 Mbps)"
        case .high: return "High (3.0 Mbps)"
        case .veryHigh: return "Very High (6.0 Mbps)"
        }
    }
}

enum ResolutionPreset: String, CaseIterable, Identifiable, Codable {
    case sd = "SD"
    case hd = "HD"
    case fhd = "FHD"
    case qhd = "QHD"

    var id: String { rawValue }
    var size: (width: Int, height: Int) {
        switch self {
        case .sd: return (854, 480)
        case .hd: return (1280, 720)
        case .fhd: return (1920, 1080)
        case .qhd: return (2560, 1440)
        }
    }
}

enum FrameRatePreset: Int, CaseIterable, Identifiable, Codable {
    case cinema = 24
    case standard = 30
    case smooth = 60

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .cinema: return "Cinema (24 fps)"
        case .standard: return "Standard (30 fps)"
        case .smooth: return "Smooth (60 fps)"
        }
    }
}

enum AudioBitratePreset: Int, CaseIterable, Identifiable, Codable {
    case low = 64
    case medium = 128
    case high = 192
    case veryHigh = 256

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .low: return "Low (64 kbps)"
        case .medium: return "Medium (128 kbps)"
        case .high: return "High (192 kbps)"
        case .veryHigh: return "Very High (256 kbps)"
        }
    }
}

enum VideoCodec: String, CaseIterable, Identifiable, Codable {
    case h264 = "H.264"
    case h265 = "H.265 (HEVC)"

    var id: String { rawValue }
    var avVideoCodecType: String { // Use AVVideoCodecType struct natively
        switch self {
        case .h264: return "avc1" // AVVideoCodecType.h264.rawValue
        case .h265: return "hvc1" // AVVideoCodecType.hevc.rawValue
        }
    }
}

struct SimpleCompressionOptions: Codable {
    var targetSizeMb: Int = 100

    static let frameRateFps = 30
    static let minVideoBitrateFhdKbps = 2000
    static let minVideoBitrateHdKbps = 500
    static let minAudioBitrateKbps = 64
    static let maxAudioBitrateKbps = 128

    static func computeMaxSizeMb(videoInfo: VideoInfo) -> Int {
        return max(10, Int((Double(videoInfo.sizeBytes) * 2.0 / 3.0) / (1024.0 * 1024.0)))
    }

    static func computeMinSizeMb(videoInfo: VideoInfo) -> Int {
        guard videoInfo.durationMs > 0 else { return 1 }
        let durationSeconds = Double(videoInfo.durationMs) / 1000.0
        let minTotalKbps = minVideoBitrateHdKbps + minAudioBitrateKbps
        return max(1, Int((Double(minTotalKbps) * 1000.0 * durationSeconds / 8.0) / (1024.0 * 1024.0)))
    }

    func computeAudioBitrateKbps(videoInfo: VideoInfo?) -> Int {
        guard let info = videoInfo, info.durationMs > 0 else { return Self.minAudioBitrateKbps }
        let targetBits = Double(targetSizeMb) * 1024.0 * 1024.0 * 8.0
        let durationSeconds = Double(info.durationMs) / 1000.0
        let totalKbps = Int(targetBits / durationSeconds / 1000.0)
        switch totalKbps {
        case 2500...: return Self.maxAudioBitrateKbps
        case 1200..<2500: return 96
        default: return Self.minAudioBitrateKbps
        }
    }

    func computeVideoBitrateKbps(videoInfo: VideoInfo?) -> Int {
        guard let info = videoInfo, info.durationMs > 0 else { return Self.minVideoBitrateFhdKbps }
        let targetBits = Double(targetSizeMb) * 1024.0 * 1024.0 * 8.0
        let durationSeconds = Double(info.durationMs) / 1000.0
        let totalBitrateKbps = Int(targetBits / durationSeconds / 1000.0)
        return max(0, totalBitrateKbps - computeAudioBitrateKbps(videoInfo: info))
    }

    func computeResolutionPreset(videoBitrateKbps: Int) -> ResolutionPreset {
        return videoBitrateKbps >= Self.minVideoBitrateFhdKbps ? .fhd : .hd
    }

    func isAchievable(videoInfo: VideoInfo?) -> Bool {
        return computeVideoBitrateKbps(videoInfo: videoInfo) >= Self.minVideoBitrateHdKbps
    }

    func toCompressionOptions(videoInfo: VideoInfo?, preferH265: Bool = true) -> CompressionOptions {
        let videoBitrateKbps = max(Self.minVideoBitrateHdKbps, computeVideoBitrateKbps(videoInfo: videoInfo))
        let audioBitrateKbps = computeAudioBitrateKbps(videoInfo: videoInfo)
        let resolution = computeResolutionPreset(videoBitrateKbps: videoBitrateKbps)
        return CompressionOptions(
            videoCodec: preferH265 ? .h265 : .h264,
            bitrateMode: .direct,
            bitrateDirectKbps: videoBitrateKbps,
            audioBitrateMode: .direct,
            audioBitrateDirectKbps: audioBitrateKbps,
            frameRateMode: .direct,
            frameRateDirectFps: Self.frameRateFps,
            resolutionMode: .preset,
            resolutionPreset: resolution
        )
    }
}

struct CompressionOptions: Codable {
    var videoCodec: VideoCodec = .h264
    var bitrateMode: BitrateMode = .preset
    var bitratePercentage: Int = 50
    var bitrateDirectKbps: Int = 2000
    var bitratePreset: BitratePreset = .medium
    var audioBitrateMode: BitrateMode = .preset
    var audioBitratePercentage: Int = 100
    var audioBitrateDirectKbps: Int = 128
    var audioBitratePreset: AudioBitratePreset = .medium
    var frameRateMode: FrameRateMode = .preset
    var frameRatePercentage: Int = 100
    var frameRateDirectFps: Int = 30
    var frameRatePreset: FrameRatePreset = .standard
    var resolutionMode: ResolutionMode = .preset
    var resolutionPercentage: Int = 100
    var resolutionDirectWidth: Int = 1280
    var resolutionDirectHeight: Int = 720
    var resolutionPreset: ResolutionPreset = .hd
    var removeAudio: Bool = false

    func computeTargetFrameRateFps(sourceFrameRate: Float) -> Int {
        var target: Int
        switch frameRateMode {
        case .percentage:
            target = Int(sourceFrameRate * (Float(frameRatePercentage) / 100.0))
        case .direct:
            target = frameRateDirectFps
        case .preset:
            target = frameRatePreset.rawValue
        }
        target = max(1, target)
        if sourceFrameRate > 0 {
            return min(target, Int(sourceFrameRate))
        }
        return target
    }

    func computeEstimatedSizeBytes(videoInfo: VideoInfo?) -> Int64 {
        guard let info = videoInfo, info.durationMs > 0 else { return 0 }

        let videoBitrateBps: Int64
        switch bitrateMode {
        case .percentage:
            videoBitrateBps = Int64(Double(info.bitrateBps) * (Double(bitratePercentage) / 100.0))
        case .direct:
            videoBitrateBps = Int64(bitrateDirectKbps) * 1000
        case .preset:
            videoBitrateBps = Int64(bitratePreset.rawValue) * 1000
        }

        let audioBitrateBps: Int64
        if removeAudio {
            audioBitrateBps = 0
        } else {
            switch audioBitrateMode {
            case .percentage:
                audioBitrateBps = Int64(Double(info.audioBitrateBps) * (Double(audioBitratePercentage) / 100.0))
            case .direct:
                audioBitrateBps = Int64(audioBitrateDirectKbps) * 1000
            case .preset:
                audioBitrateBps = Int64(audioBitratePreset.rawValue) * 1000
            }
        }

        let totalBitrateBps = videoBitrateBps + audioBitrateBps
        let durationSeconds = Double(info.durationMs) / 1000.0
        return Int64((Double(totalBitrateBps) * durationSeconds) / 8.0)
    }
}
