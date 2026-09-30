import SwiftUI

@main
struct WearTAKApp: App {
    @StateObject private var model = WatchSessionModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
