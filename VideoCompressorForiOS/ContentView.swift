import PhotosUI
import SwiftUI
import AVFoundation
import Photos

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
    @State private var compressedURL: URL?
    @State private var sourceFileSizeText = "-"
    @State private var compressedFileSizeText = "-"
    @State private var progress: Float = 0
    @State private var isCompressing = false
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    @State private var saveMessage = ""

    @State private var quality: CompressionQuality = .medium
    @State private var useHEVC = true
    @State private var includeAudio = true

    private let compressor = VideoCompressionService()

    var body: some View {
        NavigationStack {
            Form {
                Section("1. 動画を選択") {
                    PhotosPicker(selection: $selectedItem, matching: .videos) {
                        Label("動画を選択", systemImage: "video.badge.plus")
                    }

                    LabeledContent("元のサイズ") {
                        Text(sourceFileSizeText)
                    }
                }

                Section("2. 圧縮オプション") {
                    Picker("画質", selection: $quality) {
                        ForEach(CompressionQuality.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }

                    Toggle("HEVC (H.265) を優先", isOn: $useHEVC)
                    Toggle("音声を含める", isOn: $includeAudio)
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
                    compressedURL = nil
                    compressedFileSizeText = "-"
                    saveMessage = ""
                }
            } catch {
                presentError(error)
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
            let options = CompressionOptions(quality: quality, useHEVC: useHEVC, includeAudio: includeAudio)
            let resultURL = try await compressor.compress(inputURL: sourceURL, options: options) { currentProgress in
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

    private func readableFileSize(at url: URL) -> String {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let fileSize = values.fileSize
        else {
            return "-"
        }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(fileSize))
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
