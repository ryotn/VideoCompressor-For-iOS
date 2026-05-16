import Foundation
import AVFoundation
import Combine
import VideoToolbox

class VideoTranscoder {
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

        if reader.canAdd(videoOutput) { reader.add(videoOutput) }
        if writer.canAdd(videoInput) { writer.add(videoInput) }

        // Audio Settings
        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?

        if !options.removeAudio, let audioTrack = audioTrack {
            let audioBitrate = computeAudioBitrateBps()

            var channelCount = 2
            var sampleRate = 44100.0

            if let formatDescriptions = try? await audioTrack.load(.formatDescriptions) as? [CMAudioFormatDescription], let desc = formatDescriptions.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
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

            if reader.canAdd(audioReaderOutput) { reader.add(audioReaderOutput) }
            if writer.canAdd(audioWriterInput) { writer.add(audioWriterInput) }

            audioOutput = audioReaderOutput
            audioInput = audioWriterInput
        }

        // Start process
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let videoGroup = DispatchGroup()
        let videoQueue = DispatchQueue(label: "VideoEncoderQueue")

        var success = true
        var encodingError: Error?

        videoGroup.enter()
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData {
                autoreleasepool {
                    if self.isCancelled {
                        videoInput.markAsFinished()
                        videoGroup.leave()
                        return
                    }

                    if let sampleBuffer = videoOutput.copyNextSampleBuffer() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        let durationSeconds = Double(self.durationUs) / 1_000_000.0
                        let progress = durationSeconds > 0 ? min(1.0, max(0.0, Float(pts.seconds / durationSeconds))) : 1.0
                        self.onProgress(progress)
                        videoInput.append(sampleBuffer)
                    } else {
                        videoInput.markAsFinished()
                        videoGroup.leave()
                        return
                    }
                }
            }
        }

        if let audioInput = audioInput, let audioOutput = audioOutput {
            videoGroup.enter()
            let audioQueue = DispatchQueue(label: "AudioEncoderQueue")
            audioInput.requestMediaDataWhenReady(on: audioQueue) {
                while audioInput.isReadyForMoreMediaData {
                    autoreleasepool {
                        if self.isCancelled {
                            audioInput.markAsFinished()
                            videoGroup.leave()
                            return
                        }
                        if let sampleBuffer = audioOutput.copyNextSampleBuffer() {
                            audioInput.append(sampleBuffer)
                        } else {
                            audioInput.markAsFinished()
                            videoGroup.leave()
                            return
                        }
                    }
                }
            }
        }

        await withCheckedContinuation { continuation in
            videoGroup.notify(queue: .global()) {
                continuation.resume()
            }
        }

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
            await withCheckedContinuation { continuation in
                writer.finishWriting {
                    continuation.resume()
                }
            }
            if writer.status == .failed {
                success = false
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
