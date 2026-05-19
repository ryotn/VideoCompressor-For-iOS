import Foundation
import AVFoundation
import SwiftUI
import PhotosUI
import ActivityKit
import UserNotifications

@Observable
class MainViewModel {
    private enum CompletionNotificationKey {
        static let outputPath = "outputPath"
        static let originalSizeBytes = "originalSizeBytes"
        static let outputSizeBytes = "outputSizeBytes"
    }

    var videoInfo: VideoInfo?
    var compressionOptions: CompressionOptions = CompressionOptions()
    var simpleOptions: SimpleCompressionOptions = SimpleCompressionOptions()
    var compressionMode: CompressionMode = .simple
    var compressionState: CompressionState = .idle
    var saveDirectoryURL: URL?

    private static let managedTempDirectoryName = "VideoCompressorWorking"

    private var currentTranscoder: VideoTranscoder?
    private var transcodeTask: Task<Void, Never>?
    private var liveActivity: Activity<CompressionAttributes>?
    private var lastReportedProgress: Double = 0.0
    private var activeCompressionRunID: UUID?

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
        clearAllNotifications()
        clearPreviousOutputFiles()
        Self.cleanupManagedTemporaryFiles(excluding: [url])
        Self.cleanupTemporaryRootFiles(excluding: [url])

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
            if let formatDescriptions = try? await videoTrack.load(.formatDescriptions), let desc = formatDescriptions.first {
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

            Self.cleanupManagedTemporaryFiles(excluding: [url])
            Self.cleanupTemporaryRootFiles(excluding: [url])

            // Adjust simple options target size
            if let info = self.videoInfo {
                self.simpleOptions.targetSizeMb = SimpleCompressionOptions.computeMaxSizeMb(videoInfo: info)
            }
        } catch {
            print("Failed to load video info: \(error)")
            self.compressionState = .failed(error: "Failed to load video info: \(error.localizedDescription)")
            Self.cleanupManagedTemporaryFiles(excluding: [url])
            Self.cleanupTemporaryRootFiles(excluding: [url])
        }
    }

    func startCompression() {
        guard !compressionState.isActive else { return }
        guard let info = videoInfo else { return }

        clearAllNotifications()

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
        let temporaryOutputURL = Self.managedTemporaryDirectoryURL().appendingPathComponent("\(UUID().uuidString)_CompressTemp.mp4")

        Self.cleanupManagedTemporaryFiles(excluding: [info.url])
        Self.cleanupTemporaryRootFiles(excluding: [info.url])

        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }
        Self.removeFileIfExists(at: temporaryOutputURL)

        compressionState = .preparing
        self.lastReportedProgress = 0.0
        let runID = UUID()
        self.activeCompressionRunID = runID

        startLiveActivity(fileName: info.displayName)

        transcodeTask = Task {
            let transcoder = VideoTranscoder(
                inputURL: info.url,
                outputURL: temporaryOutputURL,
                options: options,
                originalBitrate: info.bitrateBps,
                originalAudioBitrate: info.audioBitrateBps,
                durationUs: info.durationMs * 1000
            ) { [weak self] progress in
                Task { @MainActor in
                    guard let self = self else { return }
                    guard self.activeCompressionRunID == runID else { return }
                    let progressPercent = min(100.0, max(0.0, progress * 100.0))
                    let roundedProgress = (progressPercent * 10).rounded() / 10
                    if case .inProgress(_, let elapsed) = self.compressionState {
                        if roundedProgress < 100.0,
                           case .inProgress(let currentProgress, _) = self.compressionState,
                           roundedProgress - currentProgress < 0.2 {
                            return
                        }
                        self.compressionState = .inProgress(progressPercent: roundedProgress, elapsedMs: elapsed)
                    } else {
                        self.compressionState = .inProgress(progressPercent: roundedProgress, elapsedMs: 0)
                    }

                    if Double(progressPercent) - self.lastReportedProgress >= 10.0 || progressPercent == 100.0 {
                        self.lastReportedProgress = Double(progressPercent)
                        self.updateLiveActivity(progress: Double(progressPercent), fileName: info.displayName)
                    }
                }
            }

            self.currentTranscoder = transcoder

            do {
                let success = try await transcoder.transcode()
                if self.activeCompressionRunID != runID {
                    Self.removeFileIfExists(at: temporaryOutputURL)
                    Self.cleanupManagedTemporaryFiles(excluding: [info.url])
                    Self.cleanupTemporaryRootFiles(excluding: [info.url])
                    return
                }

                if success {
                    do {
                        if fileManager.fileExists(atPath: outputURL.path) {
                            try? fileManager.removeItem(at: outputURL)
                        }
                        try fileManager.moveItem(at: temporaryOutputURL, to: outputURL)

                        let outputSize = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) } ?? 0
                        Task { @MainActor in
                            guard self.activeCompressionRunID == runID else { return }
                            self.compressionState = .completed(outputPath: outputURL.path, originalSizeBytes: info.sizeBytes, outputSizeBytes: outputSize)
                            self.activeCompressionRunID = nil
                            self.endLiveActivity()
                            self.sendCompletionNotification(
                                fileName: info.displayName,
                                outputPath: outputURL.path,
                                originalSizeBytes: info.sizeBytes,
                                outputSizeBytes: outputSize
                            )
                        }
                        Self.cleanupManagedTemporaryFiles(excluding: [info.url])
                        Self.cleanupTemporaryRootFiles(excluding: [info.url])
                    } catch {
                        Self.removeFileIfExists(at: temporaryOutputURL)
                        Self.removeFileIfExists(at: outputURL)
                        Task { @MainActor in
                            guard self.activeCompressionRunID == runID else { return }
                            self.compressionState = .failed(error: "Failed to finalize output file: \(error.localizedDescription)")
                            self.activeCompressionRunID = nil
                            self.endLiveActivity()
                        }
                            Self.cleanupManagedTemporaryFiles(excluding: [info.url])
                            Self.cleanupTemporaryRootFiles(excluding: [info.url])
                    }
                } else if transcoder.isCancelled {
                    Self.removeFileIfExists(at: temporaryOutputURL)
                    Self.removeFileIfExists(at: outputURL)
                    Task { @MainActor in
                        guard self.activeCompressionRunID == runID else { return }
                        self.compressionState = .cancelled
                        self.activeCompressionRunID = nil
                        self.endLiveActivity()
                    }
                        Self.cleanupManagedTemporaryFiles(excluding: [info.url])
                        Self.cleanupTemporaryRootFiles(excluding: [info.url])
                } else {
                    Self.removeFileIfExists(at: temporaryOutputURL)
                    Self.removeFileIfExists(at: outputURL)
                    Task { @MainActor in
                        guard self.activeCompressionRunID == runID else { return }
                        self.compressionState = .failed(error: "Compression failed.")
                        self.activeCompressionRunID = nil
                        self.endLiveActivity()
                    }
                        Self.cleanupManagedTemporaryFiles(excluding: [info.url])
                        Self.cleanupTemporaryRootFiles(excluding: [info.url])
                }
            } catch {
                Self.removeFileIfExists(at: temporaryOutputURL)
                Self.removeFileIfExists(at: outputURL)
                Task { @MainActor in
                    guard self.activeCompressionRunID == runID else { return }
                    self.compressionState = .failed(error: error.localizedDescription)
                    self.activeCompressionRunID = nil
                    self.endLiveActivity()
                }
                    Self.cleanupManagedTemporaryFiles(excluding: [info.url])
                    Self.cleanupTemporaryRootFiles(excluding: [info.url])
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
        let primaryActivity = liveActivity
        liveActivity = nil

        Task {
            var endedActivityIDs = Set<String>()

            if let primaryActivity = primaryActivity {
                let finalContent = ActivityContent(state: primaryActivity.content.state, staleDate: Date())
                await primaryActivity.end(finalContent, dismissalPolicy: .immediate)
                endedActivityIDs.insert(primaryActivity.id)
            }

            // Clean up orphaned activities in case local reference was lost.
            for activity in Activity<CompressionAttributes>.activities where !endedActivityIDs.contains(activity.id) {
                let finalContent = ActivityContent(state: activity.content.state, staleDate: Date())
                await activity.end(finalContent, dismissalPolicy: .immediate)
            }
        }
    }

    @MainActor
    @discardableResult
    func restoreCompletionFromNotificationUserInfo(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard
            let outputPath = userInfo[CompletionNotificationKey.outputPath] as? String,
            let originalSizeBytes = Self.int64Value(from: userInfo[CompletionNotificationKey.originalSizeBytes]),
            let outputSizeBytes = Self.int64Value(from: userInfo[CompletionNotificationKey.outputSizeBytes]),
            FileManager.default.fileExists(atPath: outputPath)
        else {
            return false
        }

        compressionState = .completed(
            outputPath: outputPath,
            originalSizeBytes: originalSizeBytes,
            outputSizeBytes: outputSizeBytes
        )
        return true
    }

    private func sendCompletionNotification(fileName: String, outputPath: String, originalSizeBytes: Int64, outputSizeBytes: Int64) {
        let content = UNMutableNotificationContent()
        content.title = "Compression Complete"
        content.body = "Finished compressing \(fileName)."
        content.sound = .default
        content.userInfo = [
            CompletionNotificationKey.outputPath: outputPath,
            CompletionNotificationKey.originalSizeBytes: originalSizeBytes,
            CompletionNotificationKey.outputSizeBytes: outputSizeBytes
        ]

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to send notification: \(error)")
            }
        }
    }

    static func clearAllNotifications() {
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

    static func managedTemporaryDirectoryURL() -> URL {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(managedTempDirectoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        return directoryURL
    }

    static func cleanupManagedTemporaryFiles(excluding urlsToKeep: [URL] = []) {
        let fileManager = FileManager.default
        let directoryURL = managedTemporaryDirectoryURL()
        let keepPaths = Set(urlsToKeep.map { $0.standardizedFileURL.path })

        guard let fileURLs = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return
        }

        for fileURL in fileURLs {
            if keepPaths.contains(fileURL.standardizedFileURL.path) {
                continue
            }
            try? fileManager.removeItem(at: fileURL)
        }
    }

    static func cleanupTemporaryRootFiles(excluding urlsToKeep: [URL] = []) {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
        let managedDirectory = managedTemporaryDirectoryURL().standardizedFileURL.path
        let keepPaths = Set(urlsToKeep.map { $0.standardizedFileURL.path })

        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: tempDirectory,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return
        }

        for fileURL in fileURLs {
            let standardizedPath = fileURL.standardizedFileURL.path
            if standardizedPath == managedDirectory || keepPaths.contains(standardizedPath) {
                continue
            }

            try? fileManager.removeItem(at: fileURL)
        }
    }

    func clearAllNotifications() {
        Self.clearAllNotifications()
    }

    private static func int64Value(from value: Any?) -> Int64? {
        switch value {
        case let intValue as Int64:
            return intValue
        case let intValue as Int:
            return Int64(intValue)
        case let numberValue as NSNumber:
            return numberValue.int64Value
        case let stringValue as String:
            return Int64(stringValue)
        default:
            return nil
        }
    }

    private static func removeFileIfExists(at url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func cancelCompression() {
        let currentInputURL = videoInfo?.url
        activeCompressionRunID = nil
        currentTranscoder?.isCancelled = true
        transcodeTask?.cancel()
        transcodeTask = nil
        currentTranscoder = nil
        endLiveActivity()
        compressionState = .cancelled
        if let currentInputURL {
            Self.cleanupManagedTemporaryFiles(excluding: [currentInputURL])
            Self.cleanupTemporaryRootFiles(excluding: [currentInputURL])
        } else {
            Self.cleanupManagedTemporaryFiles()
            Self.cleanupTemporaryRootFiles()
        }
    }

    func resetState() {
        compressionState = .idle
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
