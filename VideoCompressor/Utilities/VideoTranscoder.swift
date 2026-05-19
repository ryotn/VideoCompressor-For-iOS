import Foundation
@preconcurrency import AVFoundation
import Combine
import VideoToolbox

extension AVAssetWriterInput: @retroactive @unchecked Sendable {}
extension AVAssetReaderTrackOutput: @retroactive @unchecked Sendable {}
extension AVAssetReader: @retroactive @unchecked Sendable {}
extension AVAssetWriter: @retroactive @unchecked Sendable {}

final class VideoTranscoder: @unchecked Sendable {
    let inputURL: URL
    let outputURL: URL
    let options: CompressionOptions
    let originalBitrate: Int64
    let originalAudioBitrate: Int64
    let durationUs: Int64
    let onProgress: (Float) -> Void

    @Published var isCancelled: Bool = false

    init(inputURL: URL, outputURL: URL, options: CompressionOptions, originalBitrate: Int64, originalAudioBitrate: Int64, durationUs: Int64, onProgress: @escaping (Float) -> Void) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.options = options
        self.originalBitrate = originalBitrate
        self.originalAudioBitrate = originalAudioBitrate
        self.durationUs = durationUs
        self.onProgress = onProgress
    }

    func transcode() async throws -> Bool {
        let asset = AVURLAsset(url: inputURL)
        var shouldDeleteOutput = true
        defer {
            if shouldDeleteOutput, FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        // Wait for tracks
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "VideoTranscoder", code: -1, userInfo: [NSLocalizedDescriptionKey: "No video track found"])
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        // Video Settings
        let sourceSize = try await videoTrack.load(.naturalSize)
        let sourceTransform = try await videoTrack.load(.preferredTransform)

        let srcW = sourceSize.width
        let srcH = sourceSize.height

        let outputSize = computeOutputDimensions(srcW: Int(srcW), srcH: Int(srcH))

        let videoBitrate = computeVideoBitrateBps()

        var videoCompressionSettings: [String: Any] = [
            AVVideoAverageBitRateKey: videoBitrate,
            AVVideoProfileLevelKey: options.videoCodec == .h265 ? kVTProfileLevel_HEVC_Main_AutoLevel as String : AVVideoProfileLevelH264HighAutoLevel
        ]

        let targetFrameRate = options.computeTargetFrameRateFps(sourceFrameRate: try await videoTrack.load(.nominalFrameRate))
        videoCompressionSettings[AVVideoExpectedSourceFrameRateKey] = targetFrameRate
        videoCompressionSettings[AVVideoMaxKeyFrameIntervalKey] = targetFrameRate * 2 // 2 second keyframe interval

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: options.videoCodec == .h265 ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: outputSize.width,
            AVVideoHeightKey: outputSize.height,
            AVVideoCompressionPropertiesKey: videoCompressionSettings
        ]

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.transform = sourceTransform

        guard reader.canAdd(videoOutput) else {
            throw NSError(domain: "VideoTranscoder", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to add video reader output"])
        }
        reader.add(videoOutput)

        guard writer.canAdd(videoInput) else {
            throw NSError(domain: "VideoTranscoder", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to add video writer input"])
        }
        writer.add(videoInput)

        // Audio Settings
        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?

        if !options.removeAudio, let audioTrack = audioTrack {
            let audioBitrate = computeAudioBitrateBps()

            var channelCount = 2
            var sampleRate = 44100.0

            if let formatDescriptions = try? await audioTrack.load(.formatDescriptions), let desc = formatDescriptions.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                channelCount = Int(asbd.pointee.mChannelsPerFrame)
                sampleRate = asbd.pointee.mSampleRate
            }

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: channelCount,
                AVSampleRateKey: sampleRate,
                AVEncoderBitRateKey: audioBitrate
            ]

            let audioReaderOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            let audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)

            if reader.canAdd(audioReaderOutput), writer.canAdd(audioWriterInput) {
                reader.add(audioReaderOutput)
                writer.add(audioWriterInput)
                audioOutput = audioReaderOutput
                audioInput = audioWriterInput
            }
        }

        // Start process
        if !reader.startReading() {
            throw reader.error ?? NSError(domain: "VideoTranscoder", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to start reading"])
        }

        if !writer.startWriting() {
            throw writer.error ?? NSError(domain: "VideoTranscoder", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to start writing"])
        }
        writer.startSession(atSourceTime: .zero)

        let videoGroup = DispatchGroup()
        let videoQueue = DispatchQueue(label: "VideoEncoderQueue")

        var success = true
        var encodingError: Error?
        var finishAudioInputIfNeeded: (() -> Void)?
        var lastProgressSent: Float = -1.0
        var lastProgressSentAt = CFAbsoluteTimeGetCurrent()
        let activityLock = NSLock()
        var lastActivityAt = CFAbsoluteTimeGetCurrent()
        let stateLock = NSLock()
        var hasFailed = false
        var lastAppendedSampleTime = CMTime.zero
        let statusLock = NSLock()
        var cachedReaderStatus = reader.status
        var cachedWriterStatus = writer.status
        var lastReaderStatusCheckAt = CFAbsoluteTimeGetCurrent()

        func markActivity() {
            activityLock.lock()
            defer { activityLock.unlock() }
            lastActivityAt = CFAbsoluteTimeGetCurrent()
        }

        func stalledForMoreThan(_ seconds: TimeInterval) -> Bool {
            activityLock.lock()
            defer { activityLock.unlock() }
            return CFAbsoluteTimeGetCurrent() - lastActivityAt > seconds
        }

        func readerIsReading(force: Bool = false) -> Bool {
            let now = CFAbsoluteTimeGetCurrent()
            statusLock.lock()
            defer { statusLock.unlock() }
            if force || now - lastReaderStatusCheckAt >= 0.1 {
                cachedReaderStatus = reader.status
                cachedWriterStatus = writer.status
                lastReaderStatusCheckAt = now
            }
            return cachedReaderStatus == .reading
        }

        func writerIsWriting(force: Bool = false) -> Bool {
            let now = CFAbsoluteTimeGetCurrent()
            statusLock.lock()
            defer { statusLock.unlock() }
            if force || now - lastReaderStatusCheckAt >= 0.1 {
                cachedReaderStatus = reader.status
                cachedWriterStatus = writer.status
                lastReaderStatusCheckAt = now
            }
            return cachedWriterStatus == .writing
        }

        func readerHasFailed(force: Bool = false) -> Bool {
            let now = CFAbsoluteTimeGetCurrent()
            statusLock.lock()
            defer { statusLock.unlock() }
            if force || now - lastReaderStatusCheckAt >= 0.1 {
                cachedReaderStatus = reader.status
                cachedWriterStatus = writer.status
                lastReaderStatusCheckAt = now
            }
            return cachedReaderStatus == .failed
        }

        func emitProgressIfNeeded(_ progress: Float, force: Bool = false) {
            let now = CFAbsoluteTimeGetCurrent()
            let delta = progress - lastProgressSent
            let elapsed = now - lastProgressSentAt
            if force || lastProgressSent < 0 || progress >= 1.0 || delta >= 0.01 || elapsed >= 0.15 {
                lastProgressSent = progress
                lastProgressSentAt = now
                self.onProgress(progress)
            }
        }

        func updateLastAppendedSampleTime(_ time: CMTime) {
            guard CMTIME_IS_NUMERIC(time) else { return }
            stateLock.lock()
            defer { stateLock.unlock() }
            if CMTIME_IS_NUMERIC(lastAppendedSampleTime), CMTimeCompare(time, lastAppendedSampleTime) > 0 {
                lastAppendedSampleTime = time
            } else if !CMTIME_IS_NUMERIC(lastAppendedSampleTime) {
                lastAppendedSampleTime = time
            }
        }

        func currentLastAppendedSampleTime() -> CMTime {
            stateLock.lock()
            defer { stateLock.unlock() }
            return lastAppendedSampleTime
        }

        func isFailed() -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return hasFailed
        }

        func failOnce(message: String, underlying: Error? = nil) {
            var shouldCancelPipelines = false
            stateLock.lock()
            if !hasFailed {
                hasFailed = true
                success = false
                encodingError = underlying ?? NSError(domain: "VideoTranscoder", code: -9, userInfo: [NSLocalizedDescriptionKey: message])
                shouldCancelPipelines = true
            }
            stateLock.unlock()

            guard shouldCancelPipelines else { return }
            reader.cancelReading()
            writer.cancelWriting()
            markActivity()
        }

        func finishWritingWithinTimeout(seconds: TimeInterval) async -> Bool {
            await withCheckedContinuation { continuation in
                let continuationLock = NSLock()
                var hasResumed = false

                func resumeOnce(_ value: Bool) {
                    continuationLock.lock()
                    defer { continuationLock.unlock() }
                    guard !hasResumed else { return }
                    hasResumed = true
                    continuation.resume(returning: value)
                }

                writer.finishWriting {
                    resumeOnce(true)
                }

                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                    resumeOnce(false)
                }
            }
        }

        var didFinishVideoInput = false
        let videoFinishLock = NSLock()
        func finishVideoInputOnce() {
            videoFinishLock.lock()
            defer { videoFinishLock.unlock() }
            guard !didFinishVideoInput else { return }
            didFinishVideoInput = true
            videoInput.markAsFinished()
            videoGroup.leave()
        }

        func isVideoFinished() -> Bool {
            videoFinishLock.lock()
            defer { videoFinishLock.unlock() }
            return didFinishVideoInput
        }

        var didFinishAudioInput = true
        let audioFinishLock = NSLock()
        func isAudioFinished() -> Bool {
            audioFinishLock.lock()
            defer { audioFinishLock.unlock() }
            return didFinishAudioInput
        }

        videoGroup.enter()
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            if isVideoFinished() { return }
            var samplesProcessed = 0
            while videoInput.isReadyForMoreMediaData {
                if self.isCancelled || isFailed() || !writerIsWriting() {
                    finishVideoInputOnce()
                    return
                }
                if samplesProcessed >= 12 {
                    // Yield regularly to avoid long tight loops monopolizing CPU.
                    return
                }
                autoreleasepool {
                    if !readerIsReading() || !writerIsWriting() {
                        finishVideoInputOnce()
                        return
                    }

                    if self.isCancelled {
                        finishVideoInputOnce()
                        return
                    }

                    if let sampleBuffer = videoOutput.copyNextSampleBuffer() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        let durationSeconds = Double(self.durationUs) / 1_000_000.0
                        let progress = durationSeconds > 0 ? min(1.0, max(0.0, Float(pts.seconds / durationSeconds))) : 1.0
                        emitProgressIfNeeded(progress)
                        if !videoInput.append(sampleBuffer) {
                            failOnce(message: "Failed to append video sample.", underlying: writer.error)
                            finishVideoInputOnce()
                            return
                        }
                        samplesProcessed += 1
                        updateLastAppendedSampleTime(pts)
                        markActivity()
                    } else {
                        if readerHasFailed(force: true) {
                            failOnce(message: "Video reader failed.", underlying: reader.error)
                        }
                        finishVideoInputOnce()
                        return
                    }
                }
            }
        }

        if let audioInput = audioInput, let audioOutput = audioOutput {
            videoGroup.enter()
            let audioQueue = DispatchQueue(label: "AudioEncoderQueue")
            didFinishAudioInput = false
            func finishAudioInputOnce() {
                audioFinishLock.lock()
                defer { audioFinishLock.unlock() }
                guard !didFinishAudioInput else { return }
                didFinishAudioInput = true
                audioInput.markAsFinished()
                videoGroup.leave()
            }
            finishAudioInputIfNeeded = finishAudioInputOnce
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                if isAudioFinished() { return }
                var samplesProcessed = 0
                while audioInput.isReadyForMoreMediaData {
                    if self.isCancelled || isFailed() || !writerIsWriting() {
                        finishAudioInputOnce()
                        return
                    }
                    if samplesProcessed >= 12 {
                        return
                    }
                    autoreleasepool {
                        if !readerIsReading() || !writerIsWriting() {
                            finishAudioInputOnce()
                            return
                        }

                        if self.isCancelled {
                            finishAudioInputOnce()
                            return
                        }
                        if let sampleBuffer = audioOutput.copyNextSampleBuffer() {
                            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                            if !audioInput.append(sampleBuffer) {
                                failOnce(message: "Failed to append audio sample.", underlying: writer.error)
                                finishAudioInputOnce()
                                return
                            }
                            samplesProcessed += 1
                            updateLastAppendedSampleTime(pts)
                            markActivity()
                        } else {
                            if readerHasFailed(force: true) {
                                failOnce(message: "Audio reader failed.", underlying: reader.error)
                            }
                            finishAudioInputOnce()
                            return
                        }
                    }
                }
            }
        }

        // If callbacks stop arriving near the end, force-close pending inputs to avoid deadlock.
        let monitorTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "TranscodeMonitorQueue"))
        monitorTimer.schedule(deadline: .now() + 1.0, repeating: 0.5)
        monitorTimer.setEventHandler {
            if self.isCancelled || isFailed() {
                finishVideoInputOnce()
                finishAudioInputIfNeeded?()
                return
            }

            if !readerIsReading(force: true) || !writerIsWriting(force: true) {
                finishVideoInputOnce()
                finishAudioInputIfNeeded?()
                return
            }

            if stalledForMoreThan(6.0) && (!isVideoFinished() || !isAudioFinished()) {
                failOnce(message: "Transcode stalled while waiting for media data.")
                reader.cancelReading()
                writer.cancelWriting()
                finishVideoInputOnce()
                finishAudioInputIfNeeded?()
            }
        }
        monitorTimer.resume()

        await withCheckedContinuation { continuation in
            videoGroup.notify(queue: .global()) {
                continuation.resume()
            }
        }
        monitorTimer.cancel()

        if isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            return false
        }

        if reader.status == .failed {
            encodingError = reader.error
            success = false
        }

        if writer.status == .failed {
            encodingError = writer.error
            success = false
        }

        if success {
            let endTime = currentLastAppendedSampleTime()
            if CMTIME_IS_NUMERIC(endTime), CMTimeCompare(endTime, .zero) > 0 {
                writer.endSession(atSourceTime: endTime)
            }

            let finished = await finishWritingWithinTimeout(seconds: 10.0)
            if !finished {
                failOnce(message: "Timed out while finalizing encoded file.")
                writer.cancelWriting()
            }

            if writer.status == .failed {
                success = false
            } else {
                emitProgressIfNeeded(1.0, force: true)
            }
        }

        if !success {
            if let err = encodingError {
                throw err
            } else if let err = writer.error {
                throw err
            } else if let err = reader.error {
                throw err
            }
        }

        shouldDeleteOutput = false
        return success
    }

    private func computeVideoBitrateBps() -> Int64 {
        switch options.bitrateMode {
        case .percentage:
            return Int64(Double(originalBitrate) * (Double(options.bitratePercentage) / 100.0))
        case .direct:
            return Int64(options.bitrateDirectKbps) * 1000
        case .preset:
            return Int64(options.bitratePreset.rawValue) * 1000
        }
    }

    private func computeAudioBitrateBps() -> Int64 {
        switch options.audioBitrateMode {
        case .percentage:
            return Int64(Double(originalAudioBitrate) * (Double(options.audioBitratePercentage) / 100.0))
        case .direct:
            return Int64(options.audioBitrateDirectKbps) * 1000
        case .preset:
            return Int64(options.audioBitratePreset.rawValue) * 1000
        }
    }

    private func computeOutputDimensions(srcW: Int, srcH: Int) -> (width: Int, height: Int) {
        guard srcW > 0, srcH > 0 else { return (srcW, srcH) }

        switch options.resolutionMode {
        case .percentage:
            let scale = Float(options.resolutionPercentage) / 100.0
            return (makeEven(Int(Float(srcW) * scale)), makeEven(Int(Float(srcH) * scale)))
        case .direct:
            let scale = min(1.0, Float(options.resolutionDirectWidth) / Float(srcW), Float(options.resolutionDirectHeight) / Float(srcH))
            return (makeEven(Int(Float(srcW) * scale)), makeEven(Int(Float(srcH) * scale)))
        case .preset:
            let preset = options.resolutionPreset.size
            let maxW = srcH > srcW ? preset.height : preset.width
            let maxH = srcH > srcW ? preset.width : preset.height
            let scale = min(1.0, Float(maxW) / Float(srcW), Float(maxH) / Float(srcH))
            return (makeEven(Int(Float(srcW) * scale)), makeEven(Int(Float(srcH) * scale)))
        }
    }

    private func makeEven(_ value: Int) -> Int {
        let v = max(2, value)
        return v % 2 == 0 ? v : v - 1
    }
}
