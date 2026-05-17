import SwiftUI
import UserNotifications

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    var onNotificationTapped: (() -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            // User tapped the notification
            DispatchQueue.main.async {
                self.onNotificationTapped?()
            }
        }
        completionHandler()
    }

    // Allow showing notification while app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
struct VideoCompressorApp: App {
    @State private var mainViewModel = MainViewModel()

    init() {
        requestNotificationPermission()
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            MainScreen(viewModel: mainViewModel)
                .onAppear {
                    NotificationDelegate.shared.onNotificationTapped = {
                        // Switch to completed step if it's currently completed
                        // Note: The app state handles showing completed if compressionState is .completed
                        // But we might need a way to explicitly focus the app or ensure the step is right.
                        // For now, if the state is completed, it should already be on the completed screen.
                    }
                }
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error.localizedDescription)")
            }
        }
    }
}
