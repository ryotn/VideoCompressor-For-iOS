import AVFoundation
import Photos
import PhotosUI
import SwiftUI

private enum ScreenStep {
    case selection
    case options
    case progress
    case completed
}

private enum OptionsTab: Int, CaseIterable, Identifiable {
    case resolution
    case bitrate
    case frameRate
    case codec

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .resolution: "解像度"
        case .bitrate: "ビット\nレート"
        case .frameRate: "フレーム\nレート"
        case .codec: "コーデック"
        }
    }
}

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

    @State private var currentStep: ScreenStep = .selection
    @State private var selectedTab: OptionsTab = .resolution
    @State private var compressionFailureMessage: String?

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

    private var isAdvancedInputValid: Bool {
        if compressionMode == .simple { return true }
        if bitrateMode == .direct && bitrateDirectKbps <= 0 { return false }
        if !removeAudio && audioBitrateMode == .direct && audioBitrateDirectKbps <= 0 { return false }
        if frameRateMode == .direct && frameRateDirectFps <= 0 { return false }
        if resolutionMode == .direct && (resolutionDirectWidth <= 0 || resolutionDirectHeight <= 0) { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("VideoCompressor")
                            .font(.title)
                            .bold()

                        switch currentStep {
                        case .selection:
                            selectionStepContent
                        case .options:
                            optionsStepContent
                        case .progress:
                            progressStepContent
                        case .completed:
                            completedStepContent
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }

                Divider()

                bottomButtons
                    .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("動画圧縮くん")
            .navigationBarTitleDisplayMode(.inline)
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
                    compressionFailureMessage = nil
                    saveMessage = ""
                    currentStep = .selection
                }
            } catch {
                presentError(error)
            }
        }
    }

    private var selectionStepContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            card {
                PhotosPicker(selection: $selectedItem, matching: .videos) {
                    Label("動画を選択", systemImage: "video.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if let sourceInfo {
                    Divider()
                    infoRow("サイズ", sourceFileSizeText)
                    infoRow("長さ", formatDuration(milliseconds: sourceInfo.durationMs))
                    infoRow("解像度", "\(sourceInfo.width)×\(sourceInfo.height)")
                    infoRow("ビットレート", formatBitrate(bps: sourceInfo.bitrateBps))
                    infoRow("音声ビットレート", formatBitrate(bps: sourceInfo.audioBitrateBps))
                } else {
                    Divider()
                    Text("動画が選択されていません")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var optionsStepContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            card {
                Text("圧縮オプション")
                    .font(.headline)

                Picker("モード", selection: $compressionMode) {
                    ForEach(CompressionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            if compressionMode == .simple {
                simpleModeOptions
            } else {
                advancedModeOptions
            }
        }
    }

    private var simpleModeOptions: some View {
        card {
            Text("目標ファイルサイズ: \(Int(targetSizeMB)) MB")
            Slider(value: $targetSizeMB, in: minTargetSizeMB...maxTargetSizeMB, step: 1)

            Divider()

            let computed = currentOptions
            infoRow("推定コーデック", computed.videoCodec.rawValue)

            let target = computed.computeTargetResolution(sourceWidth: sourceInfo?.width ?? 1280, sourceHeight: sourceInfo?.height ?? 720)
            infoRow("推定解像度", "\(Int(target.width))×\(Int(target.height))")

            infoRow("推定動画ビットレート", formatBitrate(bps: computed.computeTargetVideoBitrateBps(sourceBitrateBps: sourceInfo?.bitrateBps ?? 0)))
            infoRow("推定音声ビットレート", formatBitrate(bps: computed.computeTargetAudioBitrateBps(sourceAudioBitrateBps: sourceInfo?.audioBitrateBps ?? 0)))
            infoRow("推定サイズ", estimatedSizeText)
            infoRow("推定圧縮率", estimatedRatioText)
        }
    }

    private var advancedModeOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            card {
                Picker("タブ", selection: $selectedTab) {
                    ForEach(OptionsTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                Divider()

                switch selectedTab {
                case .resolution:
                    resolutionTab
                case .bitrate:
                    bitrateTab
                case .frameRate:
                    frameRateTab
                case .codec:
                    codecTab
                }
            }

            card {
                infoRow("推定圧縮後サイズ", estimatedSizeText)
                infoRow("推定圧縮率", estimatedRatioText)
            }
        }
    }

    private var resolutionTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("解像度モード", selection: $resolutionMode) {
                ForEach(ResolutionMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            switch resolutionMode {
            case .percentage:
                Text("\(Int(resolutionPercentage))%")
                Slider(value: $resolutionPercentage, in: 10...100, step: 1)
            case .direct:
                Text("幅: \(Int(resolutionDirectWidth))")
                Slider(value: $resolutionDirectWidth, in: 320...3840, step: 2)
                Text("高さ: \(Int(resolutionDirectHeight))")
                Slider(value: $resolutionDirectHeight, in: 240...2160, step: 2)
            case .preset:
                Picker("プリセット", selection: $resolutionPreset) {
                    ForEach(ResolutionPreset.allCases) { preset in
                        let size = preset.size
                        Text("\(preset.rawValue) (\(Int(size.width))×\(Int(size.height)))").tag(preset)
                    }
                }
            }
        }
    }

    private var bitrateTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("動画ビットレート")
                .font(.subheadline)
                .bold()

            Picker("動画ビットレートモード", selection: $bitrateMode) {
                ForEach(BitrateMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            switch bitrateMode {
            case .percentage:
                Text("\(Int(bitratePercentage))%")
                Slider(value: $bitratePercentage, in: 10...100, step: 1)
            case .direct:
                Text("\(Int(bitrateDirectKbps)) kbps")
                Slider(value: $bitrateDirectKbps, in: 200...12000, step: 50)
            case .preset:
                Picker("動画プリセット", selection: $bitratePreset) {
                    ForEach(BitratePreset.allCases) { preset in
                        Text("\(preset.rawValue) (\(preset.kbps) kbps)").tag(preset)
                    }
                }
            }

            Divider()

            Text("音声ビットレート")
                .font(.subheadline)
                .bold()

            Toggle("音声なし", isOn: $removeAudio)

            if !removeAudio {
                Picker("音声ビットレートモード", selection: $audioBitrateMode) {
                    ForEach(BitrateMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                switch audioBitrateMode {
                case .percentage:
                    Text("\(Int(audioBitratePercentage))%")
                    Slider(value: $audioBitratePercentage, in: 10...100, step: 1)
                case .direct:
                    Text("\(Int(audioBitrateDirectKbps)) kbps")
                    Slider(value: $audioBitrateDirectKbps, in: 32...320, step: 8)
                case .preset:
                    Picker("音声プリセット", selection: $audioBitratePreset) {
                        ForEach(AudioBitratePreset.allCases) { preset in
                            Text("\(preset.rawValue) (\(preset.kbps) kbps)").tag(preset)
                        }
                    }
                }
            }
        }
    }

    private var frameRateTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("フレームレートモード", selection: $frameRateMode) {
                ForEach(FrameRateMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            switch frameRateMode {
            case .percentage:
                Text("\(Int(frameRatePercentage))%")
                Slider(value: $frameRatePercentage, in: 10...100, step: 1)
            case .direct:
                Text("\(Int(frameRateDirectFps)) fps")
                Slider(value: $frameRateDirectFps, in: 12...120, step: 1)
            case .preset:
                Picker("FPSプリセット", selection: $frameRatePreset) {
                    ForEach(FrameRatePreset.allCases) { preset in
                        Text(preset.rawValue).tag(preset)
                    }
                }
            }

            if let sourceInfo, sourceInfo.frameRate > 0 {
                let target = currentOptions.computeTargetFrameRate(sourceFrameRate: sourceInfo.frameRate)
                Text("出力フレームレート: \(target) fps")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var codecTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("コーデック", selection: $videoCodec) {
                ForEach(supportedCodecs) { codec in
                    Text(codec.rawValue).tag(codec)
                }
            }
        }
    }

    private var progressStepContent: some View {
        card {
            VStack(spacing: 16) {
                if isCompressing {
                    ZStack {
                        CircularProgressView(progress: progress)
                            .frame(width: 160, height: 160)
                        Text("圧縮処理中")
                            .font(.subheadline)
                    }

                    Text("\(Int(progress * 100))%")
                        .font(.title3)
                } else if let compressionFailureMessage {
                    Text("✕")
                        .font(.system(size: 88, weight: .bold))
                        .foregroundStyle(.red)
                    Text("圧縮失敗")
                        .font(.headline)
                    Text(compressionFailureMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("圧縮待機中")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private var completedStepContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            card {
                VStack(spacing: 12) {
                    Text("✓")
                        .font(.system(size: 88, weight: .bold))
                        .foregroundStyle(.green)
                    Text("圧縮完了")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)

                Divider()

                infoRow("元サイズ", sourceFileSizeText)
                infoRow("圧縮後", compressedFileSizeText)
                infoRow("圧縮率", compressedRatioText())
            }

            if let compressedURL {
                card {
                    ShareLink(item: compressedURL) {
                        Label("共有する", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        Task {
                            await saveToPhotoLibrary(videoURL: compressedURL)
                        }
                    } label: {
                        Label("写真ライブラリに保存", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    if !saveMessage.isEmpty {
                        Text(saveMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var bottomButtons: some View {
        Group {
            switch currentStep {
            case .selection:
                Button("次へ") {
                    currentStep = .options
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.borderedProminent)
                .disabled(sourceURL == nil || isCompressing)

            case .options:
                HStack(spacing: 8) {
                    Button("戻る") {
                        if compressionMode == .simple || selectedTab == .resolution {
                            currentStep = .selection
                        } else {
                            selectedTab = OptionsTab(rawValue: selectedTab.rawValue - 1) ?? .resolution
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)

                    if compressionMode == .advanced && selectedTab != .codec {
                        Button("次へ") {
                            selectedTab = OptionsTab(rawValue: selectedTab.rawValue + 1) ?? .codec
                        }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.borderedProminent)
                        .disabled(!isAdvancedInputValid)
                    } else {
                        Button("圧縮開始") {
                            Task {
                                await compressVideo()
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.borderedProminent)
                        .disabled(sourceURL == nil || isCompressing || !isAdvancedInputValid)
                    }
                }

            case .progress:
                if isCompressing {
                    ProgressView(value: Double(progress), total: 1.0)
                        .frame(maxWidth: .infinity)
                } else {
                    Button("オプションへ戻る") {
                        compressionFailureMessage = nil
                        currentStep = .options
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.bordered)
                }

            case .completed:
                Button("閉じる") {
                    currentStep = .selection
                    compressedURL = nil
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    @MainActor
    private func compressVideo() async {
        guard let sourceURL else { return }

        isCompressing = true
        compressionFailureMessage = nil
        currentStep = .progress
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
            currentStep = .completed
        } catch {
            compressionFailureMessage = error.localizedDescription
            currentStep = .progress
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

    private func compressedRatioText() -> String {
        guard
            let sourceInfo,
            sourceInfo.fileSizeBytes > 0,
            let compressedURL,
            let compressedSize = try? compressedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            compressedSize > 0
        else {
            return "-"
        }

        let ratio = (Double(compressedSize) / Double(sourceInfo.fileSizeBytes)) * 100
        return String(format: "%.1f%%", ratio)
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

private struct CircularProgressView: View {
    let progress: Float

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 8)

            Circle()
                .trim(from: 0, to: min(max(CGFloat(progress), 0), 1))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

#Preview {
    ContentView()
}
