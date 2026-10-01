import SwiftUI

@main
struct WearTAKApp: App {
    @StateObject private var model = WatchSessionModel()
    @StateObject private var physiology = PhysiologyMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, physiology: physiology)
        }
    }
}
