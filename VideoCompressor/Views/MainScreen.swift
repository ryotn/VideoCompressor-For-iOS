import SwiftUI
import PhotosUI

enum ScreenStep: Int {
    case selection = 0
    case options = 1
    case progress = 2
    case completed = 3
}

struct MainScreen: View {
    @Bindable var viewModel: MainViewModel
    @State private var selectedItem: PhotosPickerItem? = nil
    @State private var isPickerPresented = false

    @State private var currentStep: ScreenStep = .selection
    @State private var showExitDialog = false
    @State private var showCancelDialog = false
    @State private var selectedTabIndex = 0
    @State private var isDirectInputValid = true
    @State private var isLoadingVideo = false

    var body: some View {
        ZStack {
            NavigationStack {
                VStack(spacing: 0) {
                    ScrollView {
                    VStack(spacing: 12) {
                        switch currentStep {
                        case .selection:
                            SelectionStepContent(
                                videoInfo: viewModel.videoInfo,
                                saveDirectoryURL: viewModel.saveDirectoryURL,
                                isBusy: viewModel.compressionState.isActive || isLoadingVideo,
                                isLoading: isLoadingVideo,
                                onSelectVideo: { isPickerPresented = true }
                            )
                        case .options:
                            CompressionOptionsContent(
                                options: viewModel.compressionOptions,
                                videoInfo: viewModel.videoInfo,
                                viewModel: viewModel,
                                selectedTabIndex: $selectedTabIndex,
                                onValidityChanged: { isValid in
                                    isDirectInputValid = isValid
                                },
                                compressionMode: viewModel.compressionMode,
                                simpleOptions: viewModel.simpleOptions
                            )
                        case .progress:
                            ProgressStepContent(state: viewModel.compressionState)
                        case .completed:
                            CompletedStepContent(state: viewModel.compressionState)
                        }
                    }
                    .padding()
                }

                // Bottom Buttons
                VStack {
                    Divider()
                    HStack(spacing: 8) {
                        switch currentStep {
                        case .selection:
                            Button(action: { currentStep = .options }) {
                                Text("Next")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(viewModel.videoInfo != nil ? Color.blue : Color.gray)
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                            .disabled(viewModel.videoInfo == nil || viewModel.compressionState.isActive)
                        case .options:
                            Button(action: {
                                if viewModel.compressionMode == .simple || selectedTabIndex == 0 {
                                    currentStep = .selection
                                } else {
                                    selectedTabIndex -= 1
                                }
                            }) {
                                Text("Back")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.gray)
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                            .disabled(viewModel.compressionState.isActive)

                            if viewModel.compressionMode == .advanced && selectedTabIndex < 3 {
                                Button(action: { selectedTabIndex += 1 }) {
                                    Text("Next")
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(isDirectInputValid ? Color.blue : Color.gray)
                                        .foregroundColor(.white)
                                        .clipShape(Capsule())
                                }
                                .disabled(!isDirectInputValid)
                            } else {
                                Button(action: { viewModel.startCompression() }) {
                                    Text("Start Compression")
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(isDirectInputValid ? Color.green : Color.gray)
                                        .foregroundColor(.white)
                                        .clipShape(Capsule())
                                }
                                .disabled(!isDirectInputValid || viewModel.videoInfo == nil || viewModel.compressionState.isActive)
                            }
                        case .progress:
                            if viewModel.compressionState.isActive {
                                Button(action: { viewModel.cancelCompression() }) {
                                    Text("Cancel Compression")
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(Color.red)
                                        .foregroundColor(.white)
                                        .clipShape(Capsule())
                                }
                            } else {
                                Button(action: {
                                    viewModel.resetState()
                                    currentStep = .options
                                }) {
                                    Text("Back to Options")
                                        .frame(maxWidth: .infinity)
                                        .padding()
                                        .background(Color.blue)
                                        .foregroundColor(.white)
                                        .clipShape(Capsule())
                                }
                            }
                        case .completed:
                            Button(action: {
                                viewModel.clearAllNotifications()
                                viewModel.resetState()
                                currentStep = .selection
                            }) {
                                Text("Close")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color.blue)
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle(navigationTitleText)
            .navigationBarTitleDisplayMode(.inline)
            .photosPicker(isPresented: $isPickerPresented, selection: $selectedItem, matching: .videos)
            .onChange(of: selectedItem) { _, newItem in
                Task {
                    isLoadingVideo = true
                    if let file = try? await newItem?.loadTransferable(type: VideoTransferable.self) {
                        await viewModel.loadVideo(from: file.url)
                    }
                    isLoadingVideo = false
                }
            }
            .onChange(of: viewModel.compressionState.isActive) { _, isActive in
                if isActive {
                    if currentStep != .progress {
                        currentStep = .progress
                    }
                }
            }
            .onChange(of: isCompressionCompleted) { _, isCompleted in
                if isCompleted {
                    if currentStep != .completed {
                        currentStep = .completed
                    }
                }
            }
            .onAppear {
                if viewModel.compressionState.isActive {
                    currentStep = .progress
                } else if case .completed = viewModel.compressionState {
                    currentStep = .completed
                }
            }
                .alert("Cancel Compression?", isPresented: $showCancelDialog) {
                    Button("Yes", role: .destructive) { viewModel.cancelCompression() }
                    Button("No", role: .cancel) { }
                } message: {
                    Text("Are you sure you want to cancel?")
                }
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
            }

            if isLoadingVideo {
                Color.black.opacity(0.4)
                    .edgesIgnoringSafeArea(.all)

                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text("Loading video...")
                        .font(.headline)
                        .foregroundColor(.primary)
                }
                .padding(24)
                .background(Color(UIColor.systemBackground))
                .cornerRadius(12)
                .shadow(radius: 10)
            }
        }
    }

    private func handleIncomingURL(_ url: URL) {
        Task {
            isLoadingVideo = true
            let fileManager = FileManager.default
            let workingDir = MainViewModel.managedTemporaryDirectoryURL()

            // Check if it's from the share extension via custom scheme
            if url.scheme == "videocompressor", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let fileName = components.queryItems?.first(where: { $0.name == "file" })?.value {

                let groupIdentifier = "group.com.ryotn.VideoCompressor"
                if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) {
                    let sharedDirectory = groupURL.appendingPathComponent("SharedVideo")
                    let sharedFile = sharedDirectory.appendingPathComponent(fileName)

                    if fileManager.fileExists(atPath: sharedFile.path) {
                        let targetUrl = workingDir.appendingPathComponent(fileName)
                        MainViewModel.cleanupManagedTemporaryFiles()
                        try? fileManager.removeItem(at: targetUrl)
                        try? fileManager.moveItem(at: sharedFile, to: targetUrl)
                        cleanupSharedImportDirectory(sharedDirectory)

                        await viewModel.loadVideo(from: targetUrl)
                        isLoadingVideo = false
                        return
                    }

                    cleanupSharedImportDirectory(sharedDirectory)
                }
            }

            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let targetUrl = workingDir.appendingPathComponent(url.lastPathComponent)
            MainViewModel.cleanupManagedTemporaryFiles()
            try? fileManager.removeItem(at: targetUrl)

            do {
                try fileManager.copyItem(at: url, to: targetUrl)
                await viewModel.loadVideo(from: targetUrl)
            } catch {
                print("Failed to copy incoming URL: \(error)")
            }
            isLoadingVideo = false
        }
    }

    private func cleanupSharedImportDirectory(_ directoryURL: URL) {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return
        }

        for fileURL in fileURLs {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}

struct VideoTransferable: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { transferable in
            SentTransferredFile(transferable.url)
        } importing: { received in
            let fileManager = FileManager.default
            let workingDir = MainViewModel.managedTemporaryDirectoryURL()
            let targetUrl = workingDir.appendingPathComponent(received.file.lastPathComponent)
            MainViewModel.cleanupManagedTemporaryFiles()
            try? fileManager.removeItem(at: targetUrl)
            try fileManager.copyItem(at: received.file, to: targetUrl)
            return VideoTransferable(url: targetUrl)
        }
    }
}

struct SelectionStepContent: View {
    let videoInfo: VideoInfo?
    let saveDirectoryURL: URL?
    let isBusy: Bool
    let isLoading: Bool
    let onSelectVideo: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Button(action: onSelectVideo) {
                Text("Select Video")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
            .disabled(isBusy)

            if let info = videoInfo {
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.displayName).font(.headline)
                    let mb = Double(info.sizeBytes) / (1024.0 * 1024.0)
                    Text(String(format: "Size: %.2f MB", mb))

                    let totalSeconds = info.durationMs / 1000
                    let hours = totalSeconds / 3600
                    let minutes = (totalSeconds % 3600) / 60
                    let seconds = totalSeconds % 60
                    if hours > 0 {
                        Text(String(format: "Duration: %02d:%02d:%02d", hours, minutes, seconds))
                    } else {
                        Text(String(format: "Duration: %02d:%02d", minutes, seconds))
                    }

                    Text("Resolution: \(info.width) x \(info.height)")
                    Text(String(format: "Bitrate: %.1f Mbps", Double(info.bitrateBps) / 1_000_000.0))
                    Text(String(format: "Audio Bitrate: %.1f kbps", Double(info.audioBitrateBps) / 1000.0))
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6))
                .cornerRadius(10)
            } else {
                Text("No video selected")
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct CompressionOptionsContent: View {
    let options: CompressionOptions
    let videoInfo: VideoInfo?
    @Bindable var viewModel: MainViewModel
    @Binding var selectedTabIndex: Int
    let onValidityChanged: (Bool) -> Void
    let compressionMode: CompressionMode
    let simpleOptions: SimpleCompressionOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Compression Options").font(.title3)

            Picker("Mode", selection: $viewModel.compressionMode) {
                ForEach(CompressionMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if compressionMode == .simple {
                SimpleModeContent(simpleOptions: simpleOptions, videoInfo: videoInfo, viewModel: viewModel)
            } else {
                if let info = videoInfo {
                    let estSize = options.computeEstimatedSizeBytes(videoInfo: info)
                    if estSize > 0 {
                        let mb = Double(estSize) / (1024.0 * 1024.0)
                        Text(String(format: "Estimated output size: %.2f MB", mb))
                            .font(.subheadline)
                    }
                }

                Picker("Tabs", selection: $selectedTabIndex) {
                    Text("Resolution").tag(0)
                    Text("Bitrate").tag(1)
                    Text("Framerate").tag(2)
                    Text("Codec").tag(3)
                }
                .pickerStyle(.segmented)

                switch selectedTabIndex {
                case 0:
                    ResolutionTabContent(options: options, videoInfo: videoInfo, viewModel: viewModel)
                case 1:
                    BitrateTabContent(options: options, viewModel: viewModel)
                case 2:
                    FrameRateTabContent(options: options, videoInfo: videoInfo, viewModel: viewModel)
                case 3:
                    CodecTabContent(options: options, videoInfo: videoInfo, viewModel: viewModel)
                default:
                    EmptyView()
                }
            }
        }
    }
}

struct SimpleModeContent: View {
    let simpleOptions: SimpleCompressionOptions
    let videoInfo: VideoInfo?
    @Bindable var viewModel: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let sliderMin = videoInfo.map { SimpleCompressionOptions.computeMinSizeMb(videoInfo: $0) } ?? 1
            let sliderMax = videoInfo.map { SimpleCompressionOptions.computeMaxSizeMb(videoInfo: $0) } ?? 1000

            Text("Target File Size (MB)")
            HStack {
                Text("\(sliderMin)")
                Slider(
                    value: Binding(
                        get: { Double(viewModel.simpleOptions.targetSizeMb) },
                        set: { viewModel.simpleOptions.targetSizeMb = Int($0) }
                    ),
                    in: Double(sliderMin)...Double(sliderMax)
                )
                Text("\(sliderMax)")
            }
            Text("Selected: \(viewModel.simpleOptions.targetSizeMb) MB")

            if let info = videoInfo {
                let isAchievable = viewModel.simpleOptions.isAchievable(videoInfo: info)
                if !isAchievable {
                    Text("File size warning: Target may be too low for reasonable quality.")
                        .foregroundColor(.red)
                }

                let outOpts = viewModel.simpleOptions.toCompressionOptions(videoInfo: info, preferH265: true)
                VStack(alignment: .leading) {
                    Text("Computed Settings").font(.headline)
                    Text("Codec: \(outOpts.videoCodec.rawValue)")
                    Text("FPS: \(outOpts.frameRateDirectFps)")
                    Text("Resolution: \(outOpts.resolutionPreset.rawValue)")
                    Text("Video Bitrate: \(outOpts.bitrateDirectKbps) kbps")
                    Text("Audio Bitrate: \(outOpts.audioBitrateDirectKbps) kbps")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(8)
            }
        }
    }
}

struct ResolutionTabContent: View {
    let options: CompressionOptions
    let videoInfo: VideoInfo?
    @Bindable var viewModel: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $viewModel.compressionOptions.resolutionMode) {
                ForEach(ResolutionMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if options.resolutionMode == .percentage {
                HStack {
                    Text("\(options.resolutionPercentage)%")
                    if let info = videoInfo {
                        let scale = Float(options.resolutionPercentage) / 100.0
                        let w = Int(Float(info.width) * scale)
                        let h = Int(Float(info.height) * scale)
                        Text("(\(w) x \(h))")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                Slider(
                    value: Binding(get: { Double(viewModel.compressionOptions.resolutionPercentage) }, set: { viewModel.compressionOptions.resolutionPercentage = Int($0) }),
                    in: 10...100,
                    step: 5
                )
            } else if options.resolutionMode == .direct {
                HStack {
                    TextField("Width", value: $viewModel.compressionOptions.resolutionDirectWidth, format: .number)
                        .textFieldStyle(.roundedBorder)
                    TextField("Height", value: $viewModel.compressionOptions.resolutionDirectHeight, format: .number)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                Picker("Preset", selection: $viewModel.compressionOptions.resolutionPreset) {
                    ForEach(ResolutionPreset.allCases) { preset in
                        Text(formatResolutionPresetLabel(preset: preset, videoInfo: videoInfo)).tag(preset)
                    }
                }
            }
        }
    }

    private func formatResolutionPresetLabel(preset: ResolutionPreset, videoInfo: VideoInfo?) -> String {
        let baseLabel = preset.rawValue
        let dimensions = computePresetDisplayDimensions(preset: preset, videoInfo: videoInfo)
        return "\(baseLabel) (\(dimensions.width) x \(dimensions.height))"
    }

    private func computePresetDisplayDimensions(preset: ResolutionPreset, videoInfo: VideoInfo?) -> (width: Int, height: Int) {
        guard let info = videoInfo, info.width > 0, info.height > 0 else {
            return (preset.size.width, preset.size.height)
        }

        let maxW = info.height > info.width ? preset.size.height : preset.size.width
        let maxH = info.height > info.width ? preset.size.width : preset.size.height

        let scale = min(1.0, Float(maxW) / Float(info.width), Float(maxH) / Float(info.height))

        let width = makeEven(max(2, Int(Float(info.width) * scale)))
        let height = makeEven(max(2, Int(Float(info.height) * scale)))

        return (width, height)
    }

    private func makeEven(_ value: Int) -> Int {
        return value % 2 == 0 ? value : value - 1
    }
}

struct BitrateTabContent: View {
    let options: CompressionOptions
    @Bindable var viewModel: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Video Bitrate Options")
            Picker("", selection: $viewModel.compressionOptions.bitrateMode) {
                ForEach(BitrateMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if options.bitrateMode == .percentage {
                HStack {
                    Text("\(options.bitratePercentage)%")
                    if let info = viewModel.videoInfo {
                        let targetBps = Double(info.bitrateBps) * (Double(options.bitratePercentage) / 100.0)
                        let kbps = Int(targetBps / 1000.0)
                        Text("(\(kbps) kbps)")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                Slider(
                    value: Binding(get: { Double(viewModel.compressionOptions.bitratePercentage) }, set: { viewModel.compressionOptions.bitratePercentage = Int($0) }),
                    in: 10...100,
                    step: 5
                )
            } else if options.bitrateMode == .direct {
                TextField("Kbps", value: $viewModel.compressionOptions.bitrateDirectKbps, format: .number)
                    .textFieldStyle(.roundedBorder)
            } else {
                Picker("Preset", selection: $viewModel.compressionOptions.bitratePreset) {
                    ForEach(BitratePreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
            }

            Divider()

            Text("Audio Bitrate Options")
            Toggle("Remove Audio", isOn: $viewModel.compressionOptions.removeAudio)

            if !options.removeAudio {
                Picker("", selection: $viewModel.compressionOptions.audioBitrateMode) {
                    ForEach(BitrateMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if options.audioBitrateMode == .percentage {
                    HStack {
                        Text("\(options.audioBitratePercentage)%")
                        if let info = viewModel.videoInfo {
                            let targetBps = Double(info.audioBitrateBps) * (Double(options.audioBitratePercentage) / 100.0)
                            let kbps = Int(targetBps / 1000.0)
                            Text("(\(kbps) kbps)")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                        }
                    }
                    Slider(
                        value: Binding(get: { Double(viewModel.compressionOptions.audioBitratePercentage) }, set: { viewModel.compressionOptions.audioBitratePercentage = Int($0) }),
                        in: 10...100,
                        step: 5
                    )
                } else if options.audioBitrateMode == .direct {
                    TextField("Kbps", value: $viewModel.compressionOptions.audioBitrateDirectKbps, format: .number)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Picker("Preset", selection: $viewModel.compressionOptions.audioBitratePreset) {
                        ForEach(AudioBitratePreset.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                }
            }
        }
    }
}

struct FrameRateTabContent: View {
    let options: CompressionOptions
    let videoInfo: VideoInfo?
    @Bindable var viewModel: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $viewModel.compressionOptions.frameRateMode) {
                ForEach(FrameRateMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if options.frameRateMode == .percentage {
                HStack {
                    Text("\(options.frameRatePercentage)%")
                    if let info = videoInfo {
                        let targetFps = Int(info.frameRateFps * (Float(options.frameRatePercentage) / 100.0))
                        Text("(\(targetFps) fps)")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
                Slider(
                    value: Binding(get: { Double(viewModel.compressionOptions.frameRatePercentage) }, set: { viewModel.compressionOptions.frameRatePercentage = Int($0) }),
                    in: 10...100,
                    step: 5
                )
            } else if options.frameRateMode == .direct {
                TextField("FPS", value: $viewModel.compressionOptions.frameRateDirectFps, format: .number)
                    .textFieldStyle(.roundedBorder)
            } else {
                Picker("Preset", selection: $viewModel.compressionOptions.frameRatePreset) {
                    ForEach(FrameRatePreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
            }
        }
    }
}

struct CodecTabContent: View {
    let options: CompressionOptions
    let videoInfo: VideoInfo?
    @Bindable var viewModel: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Codec", selection: $viewModel.compressionOptions.videoCodec) {
                ForEach(VideoCodec.allCases) { codec in
                    Text(codec.rawValue).tag(codec)
                }
            }
        }
    }
}

struct ProgressStepContent: View {
    let state: CompressionState

    var body: some View {
        VStack(spacing: 24) {
            if case .preparing = state {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Preparing...")
                        .font(.title3)
                }
            } else if case .inProgress(let percent, _) = state {
                ProgressView(value: percent, total: 100.0) {
                    Text("Compressing...")
                } currentValueLabel: {
                    Text(String(format: "%.1f %%", percent))
                }
                .progressViewStyle(.linear)
                .padding()
            } else if case .failed(let error) = state {
                Image(systemName: "xmark.circle.fill").foregroundColor(.red).font(.largeTitle)
                Text("Failed").font(.headline)
                Text(error).foregroundColor(.secondary)
            } else if case .cancelled = state {
                Image(systemName: "xmark.circle.fill").foregroundColor(.red).font(.largeTitle)
                Text("Cancelled").font(.headline)
            }
        }
        .padding(.vertical, 40)
    }
}

struct CompletedStepContent: View {
    let state: CompressionState

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.largeTitle)
            Text("Complete").font(.headline)

            if case .completed(let path, let orig, let output) = state {
                VStack(alignment: .leading, spacing: 8) {
                    let origMb = Double(orig) / (1024.0 * 1024.0)
                    let outMb = Double(output) / (1024.0 * 1024.0)
                    Text(String(format: "Original Size: %.2f MB", origMb))
                    Text(String(format: "Compressed Size: %.2f MB", outMb))
                    if orig > 0 {
                        Text(String(format: "Ratio: %.1f %%", (outMb / origMb) * 100))
                    }
                    let fileName = URL(fileURLWithPath: path).lastPathComponent
                    Text("Saved as: \(fileName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(10)

                ShareLink(item: URL(fileURLWithPath: path)) {
                    Text("Share / Save Video")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.orange)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 40)
    }
}

extension MainScreen {
    private var isCompressionCompleted: Bool {
        if case .completed = viewModel.compressionState {
            return true
        }
        return false
    }

    private var navigationTitleText: String {
        switch currentStep {
        case .selection:
            return "Select Video"
        case .options:
            return "Compression Options"
        case .progress:
            return "Compressing..."
        case .completed:
            return "Completed"
        }
    }
}
