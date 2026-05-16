import AVFoundation
import UniformTypeIdentifiers

enum CompressionQuality: String, CaseIterable, Identifiable {
    case low = "低"
    case medium = "中"
    case high = "高"

    var id: String { rawValue }

    var presetName: String {
        switch self {
        case .low:
            AVAssetExportPreset640x480
        case .medium:
            AVAssetExportPreset960x540
        case .high:
            AVAssetExportPreset1280x720
        }
    }
}

struct CompressionOptions {
    let quality: CompressionQuality
    let useHEVC: Bool
    let includeAudio: Bool
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

        let assetForExport: AVAsset
        if options.includeAudio {
            assetForExport = sourceAsset
        } else {
            assetForExport = try await composeVideoOnlyAsset(from: sourceAsset)
        }

        let presetName = exportPreset(for: options)
        guard let exportSession = AVAssetExportSession(asset: assetForExport, presetName: presetName) else {
            throw VideoCompressionError.exportSessionCreationFailed
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("compressed-\(UUID().uuidString)")
            .appendingPathExtension(options.useHEVC ? "mov" : "mp4")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        exportSession.outputURL = outputURL
        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.outputFileType = outputFileType(for: options)

        let progressTask = Task {
            while !Task.isCancelled {
                progressHandler(exportSession.progress)
                try? await Task.sleep(for: .milliseconds(150))
            }
        }

        do {
            try await exportSession.export()
            progressTask.cancel()
            progressHandler(1.0)
            return outputURL
        } catch {
            progressTask.cancel()
            throw VideoCompressionError.exportFailed(underlying: error)
        }
    }

    private func exportPreset(for options: CompressionOptions) -> String {
        if options.useHEVC && AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality) {
            return AVAssetExportPresetHEVCHighestQuality
        }

        return options.quality.presetName
    }

    private func outputFileType(for options: CompressionOptions) -> AVFileType {
        if options.useHEVC {
            return .mov
        }

        return .mp4
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
}

private extension AVAssetExportSession {
    func export() async throws {
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
