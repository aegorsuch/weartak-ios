import SwiftUI

@main
struct WearTAKApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var model: WatchSessionModel
    @StateObject private var physiology: PhysiologyMonitor
    @StateObject private var environment: EnvironmentalMonitor

    init() {
        let settings: AppSettings
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulator-load-test") ||
            ProcessInfo.processInfo.arguments.contains("--preview-crowded-map") {
            let defaults = UserDefaults(suiteName: "WearTAK.simulatorLoadTest")!
            defaults.removePersistentDomain(forName: "WearTAK.simulatorLoadTest")
            settings = AppSettings(defaults: defaults)
            settings.multicastEnabled = false
            settings.sitxEnabled = false
            settings.relayProvider = .notSet
            if ProcessInfo.processInfo.arguments.contains("--preview-crowded-map") {
                settings.physiologicalAlertsEnabled = false
                settings.physiologicalMonitoringEnabled = false
                settings.lowPressureAlertsEnabled = false
                settings.highPressureAlertsEnabled = false
                settings.immersionAlertsEnabled = false
            }
        } else {
            settings = AppSettings()
        }
        #else
        settings = AppSettings()
        #endif
        _settings = StateObject(wrappedValue: settings)
        _model = StateObject(wrappedValue: WatchSessionModel(settings: settings))
        _physiology = StateObject(wrappedValue: PhysiologyMonitor(settings: settings))
        _environment = StateObject(wrappedValue: EnvironmentalMonitor(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, physiology: physiology, environment: environment, settings: settings)
                #if DEBUG && targetEnvironment(simulator)
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--simulator-load-test") {
                        await model.runSimulatorLoadTest()
                    }
                }
                #endif
        }
    }
}
