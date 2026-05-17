import SwiftUI

@main
struct VideoCompressorApp: App {
    @State private var mainViewModel = MainViewModel()

    var body: some Scene {
        WindowGroup {
            MainScreen(viewModel: mainViewModel)
        }
    }
}
