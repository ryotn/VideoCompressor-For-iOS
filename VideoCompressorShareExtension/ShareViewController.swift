import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private var hasStartedImport = false

    override func viewDidLoad() {
        super.viewDidLoad()
        // 共有拡張の中間UIは表示せず、即処理を開始する
        view.backgroundColor = .clear
        startImportIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 共有元によってはviewDidLoad直後に処理できないケースがあるため保険で再実行
        startImportIfNeeded()
    }

    private func startImportIfNeeded() {
        guard !hasStartedImport else { return }
        hasStartedImport = true

        Task {
            do {
                try await handleShareInput()
                var opened = await openParentAppWithRetries(maxAttempts: 3)
                if !opened {
                    // 最後の保険としてclose直前にもう一度だけ試す
                    opened = await openParentAppOnce()
                }
                await MainActor.run {
                    extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
                }
            } catch {
                await MainActor.run {
                    extensionContext?.cancelRequest(withError: error)
                }
            }
        }
    }

    private func handleShareInput() async throws {
        if SharedBridge.isCompressionRunning() {
            SharedBridge.markRejectedBecauseBusy()
            return
        }

        let attachments: [NSItemProvider] = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        guard !attachments.isEmpty else {
            throw NSError(domain: "VideoCompressorShare", code: 1002, userInfo: [NSLocalizedDescriptionKey: "共有された項目が見つかりません。"])
        }

        var resolvedVideoURLs: [URL] = []
        for attachment in attachments {
            if let url = try? await attachment.loadBestVideoURL() {
                resolvedVideoURLs.append(url)
                if resolvedVideoURLs.count > 1 { break }
            }
        }

        guard resolvedVideoURLs.count == 1, let sourceURL = resolvedVideoURLs.first else {
            throw NSError(domain: "VideoCompressorShare", code: 1003, userInfo: [NSLocalizedDescriptionKey: "動画は1つだけ選択してください。"])
        }

        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedBridge.appGroupID) else {
            throw NSError(domain: "VideoCompressorShare", code: 1005, userInfo: [NSLocalizedDescriptionKey: "App Groupが設定されていません。"])
        }

        let destinationURL = containerURL
            .appendingPathComponent("shared-\(UUID().uuidString)")
            .appendingPathExtension(sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension)

        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        try SharedBridge.writeIncomingVideoURL(destinationURL)
    }

    @MainActor
    private func openParentAppWithRetries(maxAttempts: Int) async -> Bool {
        for attempt in 0..<maxAttempts {
            let opened = await openParentAppOnce()
            if opened {
                return true
            }
            if attempt < maxAttempts - 1 {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        return false
    }

    @MainActor
    private func openParentAppOnce() async -> Bool {
        guard let url = URL(string: "\(SharedBridge.openURLScheme)://import") else { return false }

        if await openViaResponderChain(url) {
            return true
        }

        return await openViaExtensionContext(url)
    }

    @MainActor
    private func openViaResponderChain(_ url: URL) async -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                if #available(iOS 18.0, *) {
                    return await withCheckedContinuation { continuation in
                        application.open(url, options: [:]) { success in
                            continuation.resume(returning: success)
                        }
                    }
                }
                let openURLSelector = NSSelectorFromString("openURL:")
                return application.perform(openURLSelector, with: url) != nil
            }
            responder = current.next
        }
        return false
    }

    @MainActor
    private func openViaExtensionContext(_ url: URL) async -> Bool {
        guard let context = extensionContext else { return false }
        return await withCheckedContinuation { continuation in
            context.open(url) { success in
                continuation.resume(returning: success)
            }
        }
    }

    @MainActor
    private func presentErrorAndClose(_ message: String) {
        let alert = UIAlertController(title: "取り込みに失敗しました", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "閉じる", style: .default) { [weak self] _ in
            let error = NSError(domain: "VideoCompressorShare", code: 1099, userInfo: [NSLocalizedDescriptionKey: message])
            self?.extensionContext?.cancelRequest(withError: error)
        })
        present(alert, animated: true)
    }
}

private extension NSItemProvider {
    func loadBestVideoURL() async throws -> URL {
        let typeCandidates = [UTType.movie, .video, .quickTimeMovie, .mpeg4Movie].map(\.identifier)

        for typeIdentifier in typeCandidates where hasItemConformingToTypeIdentifier(typeIdentifier) {
            if let fileURL = try await resolveVideoURL(forTypeIdentifier: typeIdentifier) {
                return fileURL
            }
        }

        for typeIdentifier in registeredTypeIdentifiers {
            if let fileURL = try await resolveVideoURL(forTypeIdentifier: typeIdentifier) {
                return fileURL
            }
        }

        throw NSError(domain: "VideoCompressorShare", code: 1006, userInfo: [NSLocalizedDescriptionKey: "動画のURLを読み取れませんでした。"])
    }

    private func resolveVideoURL(forTypeIdentifier typeIdentifier: String) async throws -> URL? {
        if let item = try? await loadItemValue(forTypeIdentifier: typeIdentifier),
           let url = try? resolveURL(from: item),
           isVideoFileURL(url)
        {
            return url
        }

        if let fileURL = try? await loadFileURLValue(forTypeIdentifier: typeIdentifier),
           isVideoFileURL(fileURL)
        {
            return fileURL
        }

        return nil
    }

    func loadItemValue(forTypeIdentifier typeIdentifier: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: item)
                }
            }
        }
    }

    func loadFileURLValue(forTypeIdentifier typeIdentifier: String) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let sourceURL = url else {
                    continuation.resume(returning: nil)
                    return
                }

                // loadFileRepresentationのURLは一時URLなので、このクロージャ内で即コピーする
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("share-file-")
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension)

                do {
                    try FileManager.default.createDirectory(
                        at: tempURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if FileManager.default.fileExists(atPath: tempURL.path) {
                        try FileManager.default.removeItem(at: tempURL)
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: tempURL)
                    continuation.resume(returning: tempURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func resolveURL(from item: NSSecureCoding?) throws -> URL {
        if let url = item as? URL {
            return url
        }

        if let data = item as? Data,
           let url = URL(dataRepresentation: data, relativeTo: nil)
        {
            return url
        }

        throw NSError(domain: "VideoCompressorShare", code: 1006, userInfo: [NSLocalizedDescriptionKey: "動画のURLを読み取れませんでした。"])
    }

    private func isVideoFileURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext)
    }
}
