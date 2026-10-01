import SwiftUI

@main
struct WearTAKApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var model: WatchSessionModel
    @StateObject private var physiology: PhysiologyMonitor
    @StateObject private var environment: EnvironmentalMonitor

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: WatchSessionModel(settings: settings))
        _physiology = StateObject(wrappedValue: PhysiologyMonitor(settings: settings))
        _environment = StateObject(wrappedValue: EnvironmentalMonitor(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, physiology: physiology, environment: environment, settings: settings)
        }
    }
}
