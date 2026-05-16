import AVFoundation
import Photos
import PhotosUI
import SwiftUI

struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { pickedVideo in
            SentTransferredFile(pickedVideo.url)
        } importing: { received in
            let copiedURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString)")
                .appendingPathExtension(received.file.pathExtension)

            if FileManager.default.fileExists(atPath: copiedURL.path) {
                try FileManager.default.removeItem(at: copiedURL)
            }
            try FileManager.default.copyItem(at: received.file, to: copiedURL)
            return PickedVideo(url: copiedURL)
        }
    }
}

struct ContentView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var sourceURL: URL?
    @State private var sourceInfo: VideoInfoSummary?
    @State private var compressedURL: URL?
    @State private var sourceFileSizeText = "-"
    @State private var compressedFileSizeText = "-"
    @State private var progress: Float = 0
    @State private var isCompressing = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var saveMessage = ""

    @State private var compressionMode: CompressionMode = .simple
    @State private var targetSizeMB: Double = 100
    @State private var minTargetSizeMB: Double = 10
    @State private var maxTargetSizeMB: Double = 100

    @State private var videoCodec: VideoCodec = .h264
    @State private var bitrateMode: BitrateMode = .preset
    @State private var bitratePercentage: Double = 50
    @State private var bitrateDirectKbps: Double = 2000
    @State private var bitratePreset: BitratePreset = .medium

    @State private var audioBitrateMode: BitrateMode = .preset
    @State private var audioBitratePercentage: Double = 100
    @State private var audioBitrateDirectKbps: Double = 128
    @State private var audioBitratePreset: AudioBitratePreset = .medium

    @State private var frameRateMode: FrameRateMode = .preset
    @State private var frameRatePercentage: Double = 100
    @State private var frameRateDirectFps: Double = 30
    @State private var frameRatePreset: FrameRatePreset = .standard

    @State private var resolutionMode: ResolutionMode = .preset
    @State private var resolutionPercentage: Double = 100
    @State private var resolutionDirectWidth: Double = 1280
    @State private var resolutionDirectHeight: Double = 720
    @State private var resolutionPreset: ResolutionPreset = .hd

    @State private var removeAudio = false

    private let compressor = VideoCompressionService()

    private var supportsHEVC: Bool {
        AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality)
    }

    private var supportedCodecs: [VideoCodec] {
        supportsHEVC ? [.h264, .h265] : [.h264]
    }

    private var currentOptions: CompressionOptions {
        if compressionMode == .simple {
            let simpleOptions = SimpleCompressionOptions(targetSizeMB: Int(targetSizeMB))
            return simpleOptions.toCompressionOptions(videoInfo: sourceInfo, preferH265: supportsHEVC)
        }
        return CompressionOptions(
            videoCodec: videoCodec,
            bitrateMode: bitrateMode,
            bitratePercentage: Int(bitratePercentage),
            bitrateDirectKbps: Int(bitrateDirectKbps),
            bitratePreset: bitratePreset,
            audioBitrateMode: audioBitrateMode,
            audioBitratePercentage: Int(audioBitratePercentage),
            audioBitrateDirectKbps: Int(audioBitrateDirectKbps),
            audioBitratePreset: audioBitratePreset,
            frameRateMode: frameRateMode,
            frameRatePercentage: Int(frameRatePercentage),
            frameRateDirectFps: Int(frameRateDirectFps),
            frameRatePreset: frameRatePreset,
            resolutionMode: resolutionMode,
            resolutionPercentage: Int(resolutionPercentage),
            resolutionDirectWidth: Int(resolutionDirectWidth),
            resolutionDirectHeight: Int(resolutionDirectHeight),
            resolutionPreset: resolutionPreset,
            removeAudio: removeAudio
        )
    }

    private var estimatedSizeText: String {
        let bytes = currentOptions.computeEstimatedSizeBytes(videoInfo: sourceInfo)
        guard bytes > 0 else { return "-" }
        return readableFileSize(forBytes: bytes)
    }

    private var estimatedRatioText: String {
        guard let sourceInfo, sourceInfo.fileSizeBytes > 0 else { return "-" }
        let estimatedBytes = currentOptions.computeEstimatedSizeBytes(videoInfo: sourceInfo)
        guard estimatedBytes > 0 else { return "-" }
        let ratio = (Double(estimatedBytes) / Double(sourceInfo.fileSizeBytes)) * 100
        return String(format: "%.1f%%", ratio)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("1. 動画を選択") {
                    PhotosPicker(selection: $selectedItem, matching: .videos) {
                        Label("動画を選択", systemImage: "video.badge.plus")
                    }

                    LabeledContent("元サイズ") {
                        Text(sourceFileSizeText)
                    }

                    if let sourceInfo {
                        LabeledContent("長さ") {
                            Text(formatDuration(milliseconds: sourceInfo.durationMs))
                        }
                        LabeledContent("解像度") {
                            Text("\(sourceInfo.width)×\(sourceInfo.height)")
                        }
                        LabeledContent("動画ビットレート") {
                            Text(formatBitrate(bps: sourceInfo.bitrateBps))
                        }
                        LabeledContent("音声ビットレート") {
                            Text(formatBitrate(bps: sourceInfo.audioBitrateBps))
                        }
                    }
                }

                if sourceURL != nil {
                    Section("2. 圧縮モード") {
                        Picker("モード", selection: $compressionMode) {
                            ForEach(CompressionMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    if compressionMode == .simple {
                        simpleModeSection
                    } else {
                        advancedModeSection
                    }

                    Section("3. 圧縮") {
                        Button {
                            Task {
                                await compressVideo()
                            }
                        } label: {
                            if isCompressing {
                                Label("圧縮中...", systemImage: "hourglass")
                            } else {
                                Label("圧縮を開始", systemImage: "arrow.down.circle")
                            }
                        }
                        .disabled(sourceURL == nil || isCompressing)

                        if isCompressing {
                            ProgressView(value: Double(progress), total: 1.0)
                        }

                        LabeledContent("圧縮後サイズ") {
                            Text(compressedFileSizeText)
                        }
                    }
                }

                if let compressedURL {
                    Section("4. 保存 / 共有") {
                        ShareLink(item: compressedURL) {
                            Label("共有する", systemImage: "square.and.arrow.up")
                        }

                        Button {
                            Task {
                                await saveToPhotoLibrary(videoURL: compressedURL)
                            }
                        } label: {
                            Label("写真ライブラリに保存", systemImage: "square.and.arrow.down")
                        }

                        if !saveMessage.isEmpty {
                            Text(saveMessage)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("動画圧縮くん")
            .alert("エラー", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
        .task(id: selectedItem) {
            guard let selectedItem else { return }
            do {
                if let pickedVideo = try await selectedItem.loadTransferable(type: PickedVideo.self) {
                    sourceURL = pickedVideo.url
                    sourceFileSizeText = readableFileSize(at: pickedVideo.url)
                    sourceInfo = try await loadVideoInfo(from: pickedVideo.url)

                    if let sourceInfo {
                        minTargetSizeMB = Double(SimpleCompressionOptions.computeMinSizeMB(videoInfo: sourceInfo))
                        maxTargetSizeMB = Double(max(SimpleCompressionOptions.computeMaxSizeMB(videoInfo: sourceInfo), Int(minTargetSizeMB)))
                        let sourceSizeMB = max(Int(sourceInfo.fileSizeBytes / (1024 * 1024)), 1)
                        let defaultTarget = max(Int(minTargetSizeMB), min((sourceSizeMB * 2) / 3, Int(maxTargetSizeMB)))
                        targetSizeMB = Double(defaultTarget)
                    }

                    videoCodec = supportsHEVC ? .h265 : .h264
                    removeAudio = false
                    compressedURL = nil
                    compressedFileSizeText = "-"
                    saveMessage = ""
                }
            } catch {
                presentError(error)
            }
        }
    }

    private var simpleModeSection: some View {
        Section("簡単モード") {
            LabeledContent("目標ファイルサイズ") {
                Text("\(Int(targetSizeMB)) MB")
            }

            Slider(value: $targetSizeMB, in: minTargetSizeMB...maxTargetSizeMB, step: 1)

            let computed = currentOptions
            LabeledContent("推定コーデック") {
                Text(computed.videoCodec.rawValue)
            }
            LabeledContent("推定解像度") {
                let target = computed.computeTargetResolution(sourceWidth: sourceInfo?.width ?? 1280, sourceHeight: sourceInfo?.height ?? 720)
                Text("\(Int(target.width))×\(Int(target.height))")
            }
            LabeledContent("推定動画ビットレート") {
                Text(formatBitrate(bps: computed.computeTargetVideoBitrateBps(sourceBitrateBps: sourceInfo?.bitrateBps ?? 0)))
            }
            LabeledContent("推定音声ビットレート") {
                Text(formatBitrate(bps: computed.computeTargetAudioBitrateBps(sourceAudioBitrateBps: sourceInfo?.audioBitrateBps ?? 0)))
            }
            LabeledContent("推定圧縮後サイズ") {
                Text(estimatedSizeText)
            }
            LabeledContent("推定圧縮率") {
                Text(estimatedRatioText)
            }
        }
    }

    private var advancedModeSection: some View {
        Section("詳細モード") {
            Picker("コーデック", selection: $videoCodec) {
                ForEach(supportedCodecs) { codec in
                    Text(codec.rawValue).tag(codec)
                }
            }

            Toggle("音声なし", isOn: $removeAudio)

            Picker("動画ビットレート", selection: $bitrateMode) {
                ForEach(BitrateMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            switch bitrateMode {
            case .percentage:
                LabeledContent("動画ビットレート") {
                    Text("\(Int(bitratePercentage))%")
                }
                Slider(value: $bitratePercentage, in: 10...100, step: 1)
            case .direct:
                LabeledContent("動画ビットレート") {
                    Text("\(Int(bitrateDirectKbps)) kbps")
                }
                Slider(value: $bitrateDirectKbps, in: 200...12000, step: 50)
            case .preset:
                Picker("プリセット", selection: $bitratePreset) {
                    ForEach(BitratePreset.allCases) { preset in
                        Text("\(preset.rawValue) (\(preset.kbps) kbps)").tag(preset)
                    }
                }
            }

            Picker("音声ビットレート", selection: $audioBitrateMode) {
                ForEach(BitrateMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .disabled(removeAudio)

            if !removeAudio {
                switch audioBitrateMode {
                case .percentage:
                    LabeledContent("音声ビットレート") {
                        Text("\(Int(audioBitratePercentage))%")
                    }
                    Slider(value: $audioBitratePercentage, in: 10...100, step: 1)
                case .direct:
                    LabeledContent("音声ビットレート") {
                        Text("\(Int(audioBitrateDirectKbps)) kbps")
                    }
                    Slider(value: $audioBitrateDirectKbps, in: 32...320, step: 8)
                case .preset:
                    Picker("音声プリセット", selection: $audioBitratePreset) {
                        ForEach(AudioBitratePreset.allCases) { preset in
                            Text("\(preset.rawValue) (\(preset.kbps) kbps)").tag(preset)
                        }
                    }
                }
            }

            Picker("解像度", selection: $resolutionMode) {
                ForEach(ResolutionMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            switch resolutionMode {
            case .percentage:
                LabeledContent("解像度") {
                    Text("\(Int(resolutionPercentage))%")
                }
                Slider(value: $resolutionPercentage, in: 10...100, step: 1)
            case .direct:
                LabeledContent("幅") {
                    Text("\(Int(resolutionDirectWidth))")
                }
                Slider(value: $resolutionDirectWidth, in: 320...3840, step: 2)
                LabeledContent("高さ") {
                    Text("\(Int(resolutionDirectHeight))")
                }
                Slider(value: $resolutionDirectHeight, in: 240...2160, step: 2)
            case .preset:
                Picker("解像度プリセット", selection: $resolutionPreset) {
                    ForEach(ResolutionPreset.allCases) { preset in
                        let size = preset.size
                        Text("\(preset.rawValue) (\(Int(size.width))×\(Int(size.height)))").tag(preset)
                    }
                }
            }

            Picker("フレームレート", selection: $frameRateMode) {
                ForEach(FrameRateMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            switch frameRateMode {
            case .percentage:
                LabeledContent("フレームレート") {
                    Text("\(Int(frameRatePercentage))%")
                }
                Slider(value: $frameRatePercentage, in: 10...100, step: 1)
            case .direct:
                LabeledContent("フレームレート") {
                    Text("\(Int(frameRateDirectFps)) fps")
                }
                Slider(value: $frameRateDirectFps, in: 12...120, step: 1)
            case .preset:
                Picker("FPSプリセット", selection: $frameRatePreset) {
                    ForEach(FrameRatePreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
            }

            LabeledContent("推定圧縮後サイズ") {
                Text(estimatedSizeText)
            }
            LabeledContent("推定圧縮率") {
                Text(estimatedRatioText)
            }
        }
    }

    @MainActor
    private func compressVideo() async {
        guard let sourceURL else { return }

        isCompressing = true
        progress = 0
        saveMessage = ""

        do {
            let resultURL = try await compressor.compress(inputURL: sourceURL, options: currentOptions) { currentProgress in
                Task { @MainActor in
                    progress = currentProgress
                }
            }
            compressedURL = resultURL
            compressedFileSizeText = readableFileSize(at: resultURL)
        } catch {
            presentError(error)
        }

        isCompressing = false
    }

    @MainActor
    private func saveToPhotoLibrary(videoURL: URL) async {
        do {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if status == .notDetermined {
                _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            }

            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            }
            saveMessage = "写真ライブラリに保存しました。"
        } catch {
            presentError(error)
        }
    }

    private func loadVideoInfo(from url: URL) async throws -> VideoInfoSummary {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        guard let videoTrack else {
            throw VideoCompressionError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(transform)

        let displayWidth = Int(abs(transformedRect.width))
        let displayHeight = Int(abs(transformedRect.height))
        let durationMs = Int((CMTimeGetSeconds(duration) * 1000).rounded())
        let videoBitrateBps = Int64(try await videoTrack.load(.estimatedDataRate))
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let audioBitrateBps = Int64((try await audioTrack?.load(.estimatedDataRate)) ?? 0)

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        return VideoInfoSummary(
            durationMs: max(durationMs, 0),
            width: max(displayWidth, 0),
            height: max(displayHeight, 0),
            fileSizeBytes: max(fileSize, 0),
            bitrateBps: max(videoBitrateBps, 0),
            audioBitrateBps: max(audioBitrateBps, 0),
            frameRate: max(frameRate, 0)
        )
    }

    private func formatDuration(milliseconds: Int) -> String {
        let totalSeconds = max(milliseconds / 1000, 0)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatBitrate(bps: Int64) -> String {
        guard bps > 0 else { return "-" }
        let kbps = Double(bps) / 1000
        if kbps >= 1000 {
            return String(format: "%.1f Mbps", kbps / 1000)
        }
        return String(format: "%.0f kbps", kbps)
    }

    private func readableFileSize(at url: URL) -> String {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let fileSize = values.fileSize
        else {
            return "-"
        }

        return readableFileSize(forBytes: Int64(fileSize))
    }

    private func readableFileSize(forBytes bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    @MainActor
    private func presentError(_ error: Error) {
        errorMessage = error.localizedDescription
        showErrorAlert = true
    }
}

#Preview {
    ContentView()
}
