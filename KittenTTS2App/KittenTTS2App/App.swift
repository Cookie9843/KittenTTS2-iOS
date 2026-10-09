import SwiftUI

@main
@MainActor
struct KittenTTS2App: App {
    @StateObject private var model: AppModel
    @StateObject private var kitten2: Kitten2Model

    init() {
        let app = AppModel()
        _model = StateObject(wrappedValue: app)
        _kitten2 = StateObject(wrappedValue: Kitten2Model(app: app))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(kitten2)
        }
    }
}
