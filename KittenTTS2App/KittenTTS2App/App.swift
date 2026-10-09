import SwiftUI

@main
struct KittenTTSApp: App {
    @StateObject private var model = SpeechViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
