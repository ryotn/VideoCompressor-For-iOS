import Foundation

enum SharedBridge {
    static let appGroupID = "group.com.ryotn.VideoCompressorForiOS"
    static let inboxFileName = "incoming-video-url.txt"
    static let compressionFlagKey = "isCompressing"
    static let rejectedBecauseBusyKey = "rejectedBecauseBusy"
    static let openURLScheme = "videocompressor"

    private static var userDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func setCompressionRunning(_ isRunning: Bool) {
        userDefaults?.set(isRunning, forKey: compressionFlagKey)
    }

    static func isCompressionRunning() -> Bool {
        userDefaults?.bool(forKey: compressionFlagKey) ?? false
    }

    static func markRejectedBecauseBusy() {
        userDefaults?.set(true, forKey: rejectedBecauseBusyKey)
    }

    static func consumeRejectedBecauseBusy() -> Bool {
        let isRejected = userDefaults?.bool(forKey: rejectedBecauseBusyKey) ?? false
        if isRejected {
            userDefaults?.set(false, forKey: rejectedBecauseBusyKey)
        }
        return isRejected
    }

    static func inboxFileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(inboxFileName)
    }

    static func writeIncomingVideoURL(_ fileURL: URL) throws {
        guard let inboxURL = inboxFileURL() else {
            throw NSError(domain: "SharedBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "App Group container is unavailable."])
        }

        try fileURL.absoluteString.write(to: inboxURL, atomically: true, encoding: .utf8)
    }

    static func consumeIncomingVideoURL() -> URL? {
        guard let inboxURL = inboxFileURL(), FileManager.default.fileExists(atPath: inboxURL.path) else {
            return nil
        }

        defer {
            try? FileManager.default.removeItem(at: inboxURL)
        }

        guard
            let text = try? String(contentsOf: inboxURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
            let url = URL(string: text)
        else {
            return nil
        }
        return url
    }
}
