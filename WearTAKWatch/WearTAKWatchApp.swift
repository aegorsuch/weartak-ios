import SwiftUI

@main
struct WearTAKWatchApp: App {
    @StateObject private var model = WatchSessionModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
