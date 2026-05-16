@preconcurrency import AVFoundation
import VideoToolbox

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
    case readerCreationFailed
    case writerCreationFailed
    case invalidAudioTrack
    case compressionFailed(underlying: Error?)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            "動画トラックを読み込めませんでした。"
        case .readerCreationFailed:
            "動画の読み込みセッションの作成に失敗しました。"
        case .writerCreationFailed:
            "動画の書き込みセッションの作成に失敗しました。"
        case .invalidAudioTrack:
            "音声トラックの設定を読み込めませんでした。"
        case .compressionFailed(let underlying):
            underlying?.localizedDescription ?? "圧縮処理に失敗しました。"
        }
    }
}

final class VideoCompressionService {
    func compress(inputURL: URL, options: CompressionOptions, progressHandler: @escaping (Float) -> Void) async throws -> URL {
        let sourceAsset = AVURLAsset(url: inputURL)
        let duration = try await sourceAsset.load(.duration)
        let sourceVideoTrack = try await sourceAsset.loadTracks(withMediaType: .video).first
        let sourceAudioTrack = try await sourceAsset.loadTracks(withMediaType: .audio).first

        guard let sourceVideoTrack else {
            throw VideoCompressionError.noVideoTrack
        }

        let sourceSize = try await loadDisplaySize(for: sourceVideoTrack)
        let renderSize = options.computeRenderSize(sourceSize: sourceSize)
        let sourceVideoBitrate = Int64(try await sourceVideoTrack.load(.estimatedDataRate))
        let sourceFrameRate = try await sourceVideoTrack.load(.nominalFrameRate)
        let targetVideoBitrate = max(options.computeTargetVideoBitrateBps(sourceBitrateBps: sourceVideoBitrate), 250_000)
        let targetFrameRate = options.computeTargetFrameRate(sourceFrameRate: sourceFrameRate)

        let targetAudioBitrate: Int64
        if options.removeAudio {
            targetAudioBitrate = 0
        } else if let sourceAudioTrack {
            let sourceAudioBitrate = Int64(try await sourceAudioTrack.load(.estimatedDataRate))
            targetAudioBitrate = max(options.computeTargetAudioBitrateBps(sourceAudioBitrateBps: sourceAudioBitrate), 32_000)
        } else {
            targetAudioBitrate = 0
        }

        let outputFileType = outputFileType(for: options)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("compressed-\(UUID().uuidString)")
            .appendingPathExtension(outputFileType.fileExtension)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        guard let reader = try? AVAssetReader(asset: sourceAsset) else {
            throw VideoCompressionError.readerCreationFailed
        }

        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: outputFileType) else {
            throw VideoCompressionError.writerCreationFailed
        }

        let videoComposition = try await makeVideoComposition(
            for: sourceVideoTrack,
            duration: duration,
            sourceSize: sourceSize,
            renderSize: renderSize,
            frameRate: targetFrameRate
        )

        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [sourceVideoTrack],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            ]
        )
        videoOutput.videoComposition = videoComposition

        guard reader.canAdd(videoOutput) else {
            throw VideoCompressionError.readerCreationFailed
        }
        reader.add(videoOutput)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoOutputSettings(
                for: options,
                renderSize: renderSize,
                bitrate: targetVideoBitrate,
                frameRate: targetFrameRate
            )
        )
        videoInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput) else {
            throw VideoCompressionError.writerCreationFailed
        }
        writer.add(videoInput)

        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?

        if !options.removeAudio, let sourceAudioTrack, targetAudioBitrate > 0 {
            let configuredAudioOutput = AVAssetReaderTrackOutput(
                track: sourceAudioTrack,
                outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM]
            )

            guard reader.canAdd(configuredAudioOutput) else {
                throw VideoCompressionError.readerCreationFailed
            }
            reader.add(configuredAudioOutput)
            audioOutput = configuredAudioOutput

            let configuredAudioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: try await audioOutputSettings(for: sourceAudioTrack, bitrate: targetAudioBitrate)
            )
            configuredAudioInput.expectsMediaDataInRealTime = false

            guard writer.canAdd(configuredAudioInput) else {
                throw VideoCompressionError.writerCreationFailed
            }
            writer.add(configuredAudioInput)
            audioInput = configuredAudioInput
        }

        writer.shouldOptimizeForNetworkUse = true

        return try await transcode(
            duration: duration,
            reader: reader,
            writer: writer,
            outputURL: outputURL,
            videoOutput: videoOutput,
            videoInput: videoInput,
            audioOutput: audioOutput,
            audioInput: audioInput,
            progressHandler: progressHandler
        )
    }

    private func transcode(
        duration: CMTime,
        reader: AVAssetReader,
        writer: AVAssetWriter,
        outputURL: URL,
        videoOutput: AVAssetReaderVideoCompositionOutput,
        videoInput: AVAssetWriterInput,
        audioOutput: AVAssetReaderTrackOutput?,
        audioInput: AVAssetWriterInput?,
        progressHandler: @escaping (Float) -> Void
    ) async throws -> URL {
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.001)
        let videoQueue = DispatchQueue(label: "VideoCompressionService.video")
        let audioQueue = DispatchQueue(label: "VideoCompressionService.audio")
        let stateQueue = DispatchQueue(label: "VideoCompressionService.state")
        let readerBox = SendableBox(reader)
        let writerBox = SendableBox(writer)
        let videoOutputBox = SendableBox(videoOutput)
        let videoInputBox = SendableBox(videoInput)
        let audioOutputBox = audioOutput.map(SendableBox.init)
        let audioInputBox = audioInput.map(SendableBox.init)

        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            var isFinishing = false
            var videoFinished = false
            var audioFinished = audioInputBox == nil
            var firstError: Error?

            func resolve(_ result: Result<URL, Error>) {
                stateQueue.sync {
                    guard !hasResumed else { return }
                    hasResumed = true
                    switch result {
                    case .success(let url):
                        continuation.resume(returning: url)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }

            func fail(_ error: Error?) {
                let resolvedError: Error = stateQueue.sync {
                    if let firstError {
                        return firstError
                    }
                    let newError = error ?? VideoCompressionError.compressionFailed(underlying: nil)
                    firstError = newError
                    return newError
                }
                readerBox.value.cancelReading()
                writerBox.value.cancelWriting()
                resolve(.failure(resolvedError))
            }

            func finishIfNeeded() {
                let shouldFinish: Bool = stateQueue.sync {
                    guard !hasResumed, !isFinishing, firstError == nil else { return false }
                    guard videoFinished && audioFinished else { return false }
                    isFinishing = true
                    return true
                }

                guard shouldFinish else { return }

                writerBox.value.finishWriting {
                    if writerBox.value.status == .completed {
                        progressHandler(1.0)
                        resolve(.success(outputURL))
                    } else {
                        fail(writerBox.value.error)
                    }
                }
            }

            guard writerBox.value.startWriting() else {
                fail(writerBox.value.error)
                return
            }

            guard readerBox.value.startReading() else {
                fail(readerBox.value.error)
                return
            }

            writerBox.value.startSession(atSourceTime: .zero)

            videoInputBox.value.requestMediaDataWhenReady(on: videoQueue) {
                while videoInputBox.value.isReadyForMoreMediaData {
                    if let sampleBuffer = videoOutputBox.value.copyNextSampleBuffer() {
                        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        let progress = min(max(Float(CMTimeGetSeconds(presentationTime) / durationSeconds), 0), 0.99)
                        progressHandler(progress)

                        guard videoInputBox.value.append(sampleBuffer) else {
                            fail(writerBox.value.error ?? readerBox.value.error)
                            return
                        }
                    } else {
                        videoInputBox.value.markAsFinished()
                        stateQueue.sync {
                            videoFinished = true
                            if readerBox.value.status == .failed, firstError == nil {
                                firstError = readerBox.value.error ?? VideoCompressionError.compressionFailed(underlying: nil)
                            }
                        }
                        finishIfNeeded()
                        return
                    }
                }
            }

            if let audioInputBox, let audioOutputBox {
                audioInputBox.value.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInputBox.value.isReadyForMoreMediaData {
                        if let sampleBuffer = audioOutputBox.value.copyNextSampleBuffer() {
                            guard audioInputBox.value.append(sampleBuffer) else {
                                fail(writerBox.value.error ?? readerBox.value.error)
                                return
                            }
                        } else {
                            audioInputBox.value.markAsFinished()
                            stateQueue.sync {
                                audioFinished = true
                                if readerBox.value.status == .failed, firstError == nil {
                                    firstError = readerBox.value.error ?? VideoCompressionError.compressionFailed(underlying: nil)
                                }
                            }
                            finishIfNeeded()
                            return
                        }
                    }
                }
            }
        }
    }

    private func videoOutputSettings(
        for options: CompressionOptions,
        renderSize: CGSize,
        bitrate: Int64,
        frameRate: Int
    ) -> [String: Any] {
        [
            AVVideoCodecKey: videoCodec(for: options.videoCodec),
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(bitrate),
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: max(frameRate * 2, 1),
                AVVideoProfileLevelKey: profileLevel(for: options.videoCodec)
            ]
        ]
    }

    private func audioOutputSettings(for track: AVAssetTrack, bitrate: Int64) async throws -> [String: Any] {
        let formatDescriptions = try await track.load(.formatDescriptions)
        let streamDescription = formatDescriptions
            .compactMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            .first

        let sampleRate = streamDescription.map { Int($0.mSampleRate) }.flatMap { $0 > 0 ? $0 : nil } ?? 44_100
        let channelCount = streamDescription.map { Int($0.mChannelsPerFrame) }.flatMap { $0 > 0 ? $0 : nil } ?? 2

        guard sampleRate > 0, channelCount > 0 else {
            throw VideoCompressionError.invalidAudioTrack
        }

        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: Int(bitrate)
        ]
    }

    private func makeVideoComposition(
        for track: AVAssetTrack,
        duration: CMTime,
        sourceSize: CGSize,
        renderSize: CGSize,
        frameRate: Int
    ) async throws -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(frameRate, 1)))

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let preferredTransform = try await track.load(.preferredTransform)
        let naturalSize = try await track.load(.naturalSize)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let orientedSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
        let scale = min(renderSize.width / max(orientedSize.width, 1), renderSize.height / max(orientedSize.height, 1))
        let scaledRect = CGRect(origin: transformedRect.origin, size: transformedRect.size)
            .applying(CGAffineTransform(scaleX: scale, y: scale))

        var finalTransform = preferredTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        finalTransform = finalTransform.concatenating(
            CGAffineTransform(
                translationX: (renderSize.width - abs(scaledRect.width)) / 2 - scaledRect.origin.x,
                y: (renderSize.height - abs(scaledRect.height)) / 2 - scaledRect.origin.y
            )
        )

        layerInstruction.setTransform(finalTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]
        return composition
    }

    private func videoCodec(for codec: VideoCodec) -> AVVideoCodecType {
        switch codec {
        case .h265:
            return .hevc
        case .h264, .av1:
            return .h264
        }
    }

    private func profileLevel(for codec: VideoCodec) -> String {
        switch codec {
        case .h265:
            return kVTProfileLevel_HEVC_Main_AutoLevel as String
        case .h264, .av1:
            return AVVideoProfileLevelH264HighAutoLevel
        }
    }

    private func outputFileType(for options: CompressionOptions) -> AVFileType {
        options.videoCodec == .h265 ? .mov : .mp4
    }

    private func loadDisplaySize(for track: AVAssetTrack) async throws -> CGSize {
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
    }
}

private final class SendableBox<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

private extension CompressionOptions {
    func computeRenderSize(sourceSize: CGSize) -> CGSize {
        let target = computeTargetResolution(
            sourceWidth: Int(max(sourceSize.width, 0)),
            sourceHeight: Int(max(sourceSize.height, 0))
        )

        let resolvedSize: CGSize
        switch resolutionMode {
        case .direct:
            resolvedSize = target
        case .percentage, .preset:
            guard sourceSize.width > 0, sourceSize.height > 0, target.width > 0, target.height > 0 else {
                resolvedSize = target
                break
            }

            let scale = min(target.width / sourceSize.width, target.height / sourceSize.height)
            resolvedSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        }

        return CGSize(
            width: max((Int(resolvedSize.width.rounded()) / 2) * 2, 2),
            height: max((Int(resolvedSize.height.rounded()) / 2) * 2, 2)
        )
    }
}

private extension AVFileType {
    var fileExtension: String {
        switch self {
        case .mov:
            return "mov"
        default:
            return "mp4"
        }
    }
}
