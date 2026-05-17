import Foundation
import AVFoundation
import SwiftUI
import PhotosUI
import ActivityKit

@Observable
class MainViewModel {
    var videoInfo: VideoInfo?
    var compressionOptions: CompressionOptions = CompressionOptions()
    var simpleOptions: SimpleCompressionOptions = SimpleCompressionOptions()
    var compressionMode: CompressionMode = .simple
    var compressionState: CompressionState = .idle
    var saveDirectoryURL: URL?

    private var currentTranscoder: VideoTranscoder?
    private var transcodeTask: Task<Void, Never>?
    private var liveActivity: Activity<CompressionAttributes>?
    private var lastReportedProgress: Double = 0.0

    // Supported codecs (only checking what hardware supports is ideal, but let's assume standard ones are available)
    let supportedVideoCodecs: [VideoCodec] = [.h264, .h265]

    func updateOptions(_ options: CompressionOptions) {
        self.compressionOptions = options
    }

    func updateCompressionMode(_ mode: CompressionMode) {
        self.compressionMode = mode
    }

    func updateSimpleOptions(_ options: SimpleCompressionOptions) {
        self.simpleOptions = options
    }

    @MainActor
    func loadVideo(from url: URL) async {
        clearPreviousOutputFiles()

        do {
            let asset = AVURLAsset(url: url)

            guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { return }
            let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

            let sizeBytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) } ?? 0
            let durationMs = Int64(try await asset.load(.duration).seconds * 1000)

            let naturalSize = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            let isPortrait = abs(transform.a) < 0.01 && abs(transform.d) < 0.01

            let width = isPortrait ? Int(naturalSize.height) : Int(naturalSize.width)
            let height = isPortrait ? Int(naturalSize.width) : Int(naturalSize.height)

            let bitrateBps = try await videoTrack.load(.estimatedDataRate)
            let audioBitrateBps = (try? await audioTrack?.load(.estimatedDataRate)) ?? 0
            let frameRateFps = try await videoTrack.load(.nominalFrameRate)

            // simple check for codec
            var videoCodecMime: String? = nil
            if let formatDescriptions = try? await videoTrack.load(.formatDescriptions) as? [CMFormatDescription], let desc = formatDescriptions.first {
                let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
                if mediaSubType == kCMVideoCodecType_HEVC {
                    videoCodecMime = "video/hevc"
                } else if mediaSubType == kCMVideoCodecType_H264 {
                    videoCodecMime = "video/avc"
                }
            }

            self.videoInfo = VideoInfo(
                url: url,
                displayName: url.lastPathComponent,
                sizeBytes: sizeBytes,
                durationMs: durationMs,
                width: width,
                height: height,
                bitrateBps: Int64(bitrateBps),
                audioBitrateBps: Int64(audioBitrateBps),
                frameRateFps: frameRateFps,
                videoCodecMime: videoCodecMime
            )

            // Adjust simple options target size
            if let info = self.videoInfo {
                self.simpleOptions.targetSizeMb = SimpleCompressionOptions.computeMaxSizeMb(videoInfo: info)
            }
        } catch {
            print("Failed to load video info: \(error)")
            self.compressionState = .failed(error: "Failed to load video info: \(error.localizedDescription)")
        }
    }

    func startCompression() {
        guard !compressionState.isActive else { return }
        guard let info = videoInfo else { return }

        let options: CompressionOptions
        switch compressionMode {
        case .simple:
            options = simpleOptions.toCompressionOptions(videoInfo: info, preferH265: supportedVideoCodecs.contains(.h265))
        case .advanced:
            options = compressionOptions
        }

        let fileManager = FileManager.default
        let outputDirectory = saveDirectoryURL ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let originalName = (info.displayName as NSString).deletingPathExtension
        let outputFileName = "\(originalName)_Compress.mp4"
        let outputURL = outputDirectory.appendingPathComponent(outputFileName)

        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }

        compressionState = .preparing
        self.lastReportedProgress = 0.0

        clearNotifications()
        startLiveActivity(fileName: info.displayName)

        transcodeTask = Task {
            let transcoder = VideoTranscoder(
                inputURL: info.url,
                outputURL: outputURL,
                options: options,
                originalBitrate: info.bitrateBps,
                originalAudioBitrate: info.audioBitrateBps,
                durationUs: info.durationMs * 1000
            ) { [weak self] progress in
                Task { @MainActor in
                    guard let self = self else { return }
                    let progressPercent = progress * 100.0
                    if case .inProgress(_, let elapsed) = self.compressionState {
                        self.compressionState = .inProgress(progressPercent: progressPercent, elapsedMs: elapsed)
                    } else {
                        self.compressionState = .inProgress(progressPercent: progressPercent, elapsedMs: 0)
                    }

                    let progressPercentDouble = Double(progressPercent)
                    if progressPercentDouble - self.lastReportedProgress >= 10.0 || progressPercentDouble >= 100.0 {
                        self.lastReportedProgress = progressPercentDouble
                        self.updateLiveActivity(progress: progressPercentDouble, fileName: info.displayName)
                    }
                }
            }

            self.currentTranscoder = transcoder

            do {
                let success = try await transcoder.transcode()
                if success {
                    let outputSize = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) } ?? 0
                    Task { @MainActor in
                        self.compressionState = .completed(outputPath: outputURL.path, originalSizeBytes: info.sizeBytes, outputSizeBytes: outputSize)
                        self.endLiveActivity()
                        self.sendCompletionNotification(fileName: info.displayName)
                    }
                } else if transcoder.isCancelled {
                    Task { @MainActor in
                        self.compressionState = .cancelled
                        self.endLiveActivity()
                    }
                } else {
                    Task { @MainActor in
                        self.compressionState = .failed(error: "Compression failed.")
                        self.endLiveActivity()
                    }
                }
            } catch {
                Task { @MainActor in
                    self.compressionState = .failed(error: error.localizedDescription)
                    self.endLiveActivity()
                }
            }
        }
    }

    private func startLiveActivity(fileName: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard liveActivity == nil else { return }

        let initialContentState = CompressionAttributes.ContentState(progressPercent: 0.0)
        let activityAttributes = CompressionAttributes(fileName: fileName, totalSizeMb: nil)

        let activityContent = ActivityContent(state: initialContentState, staleDate: nil)

        do {
            liveActivity = try Activity.request(attributes: activityAttributes, content: activityContent)
        } catch {
            print("Failed to start Live Activity: \(error)")
        }
    }

    private func updateLiveActivity(progress: Double, fileName: String) {
        guard let liveActivity = liveActivity else { return }
        let updatedContentState = CompressionAttributes.ContentState(progressPercent: progress)
        let updatedContent = ActivityContent(state: updatedContentState, staleDate: nil)
        Task {
            await liveActivity.update(updatedContent)
        }
    }

    private func endLiveActivity() {
        guard let activity = liveActivity else { return }
        liveActivity = nil
        Task {
            let finalContentState = activity.content.state
            let finalContent = ActivityContent(state: finalContentState, staleDate: nil)
            await activity.end(finalContent, dismissalPolicy: .immediate)
        }
    }

    private func sendCompletionNotification(fileName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Compression Complete"
        content.body = "Finished compressing \(fileName)."
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to send notification: \(error)")
            }
        }
    }

    func clearNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()

        if #available(iOS 16.0, *) {
            center.setBadgeCount(0) { error in
                if let error = error {
                    print("Failed to clear badge count: \(error.localizedDescription)")
                }
            }
        } else {
            DispatchQueue.main.async {
                UIApplication.shared.applicationIconBadgeNumber = 0
            }
        }
    }

    func cancelCompression() {
        currentTranscoder?.isCancelled = true
        transcodeTask?.cancel()
    }

    func resetState() {
        compressionState = .idle
        clearNotifications()
    }

    private func clearPreviousOutputFiles() {
        let fileManager = FileManager.default
        guard let outputDirectory = saveDirectoryURL ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: outputDirectory, includingPropertiesForKeys: nil)
            for fileURL in fileURLs {
                if fileURL.lastPathComponent.hasSuffix("_Compress.mp4") {
                    try? fileManager.removeItem(at: fileURL)
                }
            }
        } catch {
            print("Failed to clear previous output files: \(error)")
        }
    }
}
