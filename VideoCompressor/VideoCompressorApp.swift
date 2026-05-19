import SwiftUI
import UIKit
import UserNotifications

private enum PendingCompletionNotificationStore {
    private static let key = "pending_completion_notification_user_info"

    static func save(_ userInfo: [AnyHashable: Any]) {
        var storable: [String: Any] = [:]
        for (k, v) in userInfo {
            if let key = k as? String {
                storable[key] = v
            }
        }
        UserDefaults.standard.set(storable, forKey: key)
    }

    static func consume() -> [AnyHashable: Any]? {
        guard let stored = UserDefaults.standard.dictionary(forKey: key) else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        return stored
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Failed to request notification authorization: \(error)")
            }
            if !granted {
                print("Notification permission not granted.")
            }
        }
        MainViewModel.clearAllNotifications()
        MainViewModel.cleanupManagedTemporaryFiles()
        MainViewModel.cleanupTemporaryRootFiles()
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        PendingCompletionNotificationStore.save(response.notification.request.content.userInfo)
        MainViewModel.clearAllNotifications()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .list, .sound, .badge]
    }
}

@main
struct VideoCompressorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var mainViewModel = MainViewModel()

    init() {
        MainViewModel.clearAllNotifications()
        MainViewModel.cleanupManagedTemporaryFiles()
        MainViewModel.cleanupTemporaryRootFiles()
    }

    var body: some Scene {
        WindowGroup {
            MainScreen(viewModel: mainViewModel)
                .onAppear {
                    restoreCompletionFromPendingNotificationIfNeeded()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        restoreCompletionFromPendingNotificationIfNeeded()
                    }
                }
        }
    }

    private func restoreCompletionFromPendingNotificationIfNeeded() {
        guard let userInfo = PendingCompletionNotificationStore.consume() else { return }
        _ = mainViewModel.restoreCompletionFromNotificationUserInfo(userInfo)
    }
}
