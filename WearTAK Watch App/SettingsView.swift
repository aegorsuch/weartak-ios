import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            NavigationLink("Device Preferences") {
                DevicePreferencesView(model: model)
            }
            NavigationLink("Network Preferences") {
                NetworkPreferencesView(model: model, settings: settings)
            }
            NavigationLink("Alerting Preferences") {
                AlertingPreferencesView(settings: settings)
            }
            NavigationLink("Tool Preferences") {
                ToolPreferencesView(settings: settings)
            }
        }
        .navigationTitle("Settings")
    }
}

private struct DevicePreferencesView: View {
    @ObservedObject var model: WatchSessionModel

    private var locationServicesLabel: String {
        model.lastLocation != nil ? "On" : "Off"
    }

    var body: some View {
        List {
            LabeledContent("Location Services", value: locationServicesLabel)
        }
        .navigationTitle("Device Preferences")
    }
}

private struct NetworkPreferencesView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Section {
                TextField("Watch label", text: $settings.watchLabel)
            }
            Section {
                LabeledContent("ATAK Connect", value: model.connectionState.rawValue)
            }
        }
        .navigationTitle("Network Preferences")
    }
}

private struct AlertingPreferencesView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            NavigationLink {
                PhysiologicalAlertsView(settings: settings)
            } label: {
                Toggle("Physiological Alerts", isOn: $settings.physiologicalAlertsEnabled)
                    .toggleStyle(.switch)
            }
            NavigationLink("Environmental Alerts") {
                EnvironmentalAlertsView(settings: settings)
            }
        }
        .navigationTitle("Alerting Preferences")
    }
}

private struct PhysiologicalAlertsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Toggle("Physiological Alerts", isOn: $settings.physiologicalAlertsEnabled)
            Section("Resting Heart Rate Alerts") {
                Stepper(
                    "High HR Threshold: \(settings.highRestingHeartRate) bpm",
                    value: $settings.highRestingHeartRate, in: 80...220
                )
                Stepper(
                    "Low HR Threshold: \(settings.lowRestingHeartRate) bpm",
                    value: $settings.lowRestingHeartRate, in: 25...110
                )
            }
            Section("Exertion Alerts") {
                Stepper(
                    "Warning Threshold: \(settings.exertionWarningThreshold)%",
                    value: $settings.exertionWarningThreshold, in: 50...100
                )
                Stepper(
                    "Alert Threshold: \(settings.exertionAlertThreshold)%",
                    value: $settings.exertionAlertThreshold, in: 50...100
                )
            }
        }
        .navigationTitle("Physiological Alerts")
    }
}

private struct EnvironmentalAlertsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Section("Atm Pressure Alerts") {
                Toggle("Low Pressure Alert", isOn: $settings.lowPressureAlertsEnabled)
                Stepper(
                    "Pressure Threshold: \(settings.lowPressureThreshold) hPa",
                    value: $settings.lowPressureThreshold, in: 800...1100, step: 5
                )
                Toggle("High Pressure Alert", isOn: $settings.highPressureAlertsEnabled)
                Stepper(
                    "Pressure Threshold: \(settings.highPressureThreshold) hPa",
                    value: $settings.highPressureThreshold, in: 1000...3000, step: 5
                )
            }
            Section("Immersion Alerts") {
                Toggle("Immersion Alerts", isOn: $settings.immersionAlertsEnabled)
            }
        }
        .navigationTitle("Environmental Alerts")
    }
}

private struct ToolPreferencesView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            NavigationLink("Bloodhound") {
                BloodhoundPreferencesView(settings: settings)
            }
        }
        .navigationTitle("Tool Preferences")
    }
}

private struct BloodhoundPreferencesView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Toggle("Bloodhound Proximity Vibration", isOn: $settings.bloodhoundProximityVibrationEnabled)
            Stepper(
                "Bloodhound Proximity Radius: \(settings.bloodhoundProximityRadius) meters",
                value: $settings.bloodhoundProximityRadius, in: 10...200, step: 10
            )
        }
        .navigationTitle("Navigation")
    }
}
