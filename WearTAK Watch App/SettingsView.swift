import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var settings: AppSettings
    @StateObject private var sitxClient: SitxClient

    init(model: WatchSessionModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        _sitxClient = StateObject(wrappedValue: SitxClient(settings: settings))
    }

    var body: some View {
        List {
            NavigationLink("Device Preferences") {
                DevicePreferencesView(settings: settings)
            }
            NavigationLink("Network Preferences") {
                NetworkPreferencesView(model: model, settings: settings, sitxClient: sitxClient)
            }
            NavigationLink("Alerting Preferences") {
                AlertingPreferencesView(settings: settings)
            }
            NavigationLink("Tool Preferences") {
                ToolPreferencesView(settings: settings)
            }
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")")
                .foregroundStyle(.secondary)
        }
        .navigationTitle("Settings")
    }
}

private struct DevicePreferencesView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            NavigationLink("My User Metrics") {
                UserMetricsView(settings: settings)
            }
        }
        .navigationTitle("Device Preferences")
    }
}

private struct UserMetricsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            NavigationLink("Medical Profile (BATDOK)") {
                MedicalProfileView(settings: settings)
            }
            NavigationLink("Gait Tracking") {
                GaitTrackingView(settings: settings)
            }
        }
        .navigationTitle("My User Metrics")
    }
}

private struct MedicalProfileView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            NavigationLink {
                ProfileNumberPickerView(
                    title: "Birth Year", selection: $settings.birthYear,
                    values: Array(1920...Calendar.current.component(.year, from: Date())),
                    valueLabel: { "\($0)" }
                )
            } label: {
                LabeledContent("Birth Year", value: "\(settings.birthYear)")
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: "Height", selection: $settings.heightInches,
                    values: Array(48...84),
                    valueLabel: { "\($0 / 12)' \($0 % 12)\u{22}" }
                )
            } label: {
                LabeledContent("Height", value: "\(settings.heightInches / 12)' \(settings.heightInches % 12)\u{22}")
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: "Weight", selection: $settings.weightPounds,
                    values: Array(stride(from: 80, through: 320, by: 5)),
                    valueLabel: { "\($0) lb" }
                )
            } label: {
                LabeledContent("Weight", value: "\(settings.weightPounds) lb")
            }
            NavigationLink {
                ProfileStringPickerView(title: "Sex", selection: $settings.sex, values: AppSettings.sexOptions)
            } label: {
                LabeledContent("Sex", value: settings.sex)
            }
            NavigationLink {
                ProfileStringPickerView(title: "Blood Type", selection: $settings.bloodType, values: AppSettings.bloodTypeOptions)
            } label: {
                LabeledContent("Blood Type", value: settings.bloodType)
            }
            NavigationLink {
                AllergiesView(settings: settings)
            } label: {
                LabeledContent("Allergies", value: settings.allergies.joined(separator: ", "))
            }
            NavigationLink {
                ProfileStringPickerView(title: "User Type", selection: $settings.userType, values: AppSettings.userTypeOptions)
            } label: {
                LabeledContent("User Type", value: settings.userType)
            }
        }
        .navigationTitle("Medical Profile (BATDOK)")
    }
}

private struct ProfileNumberPickerView: View {
    let title: String
    @Binding var selection: Int
    let values: [Int]
    let valueLabel: (Int) -> String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(values, id: \.self) { value in
            Button {
                selection = value
                dismiss()
            } label: {
                HStack {
                    Text(valueLabel(value))
                    Spacer()
                    if selection == value {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        .navigationTitle(title)
    }
}

private struct ProfileStringPickerView: View {
    let title: String
    @Binding var selection: String
    let values: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(values, id: \.self) { value in
            Button {
                selection = value
                dismiss()
            } label: {
                HStack {
                    Text(value)
                    Spacer()
                    if selection == value {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        .navigationTitle(title)
    }
}

private struct AllergiesView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List(AppSettings.allergyOptions, id: \.self) { allergy in
            Button {
                settings.toggleAllergy(allergy)
            } label: {
                HStack {
                    Text(allergy)
                    Spacer()
                    if settings.allergies.contains(allergy) {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        .navigationTitle("Allergies")
    }
}

private struct GaitTrackingView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            NavigationLink {
                ProfileNumberPickerView(
                    title: "Uniform Waist Size", selection: $settings.uniformWaistSize,
                    values: Array(24...60), valueLabel: { "\($0) in" }
                )
            } label: {
                LabeledContent("Uniform Waist Size", value: "\(settings.uniformWaistSize) in")
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: "Stride Length", selection: $settings.strideLength,
                    values: Array(20...45), valueLabel: { "\($0) in" }
                )
            } label: {
                LabeledContent("Stride Length", value: "\(settings.strideLength) in")
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: "Uniform Pants Length", selection: $settings.uniformPantsLength,
                    values: Array(24...60), valueLabel: { "\($0) in" }
                )
            } label: {
                LabeledContent("Uniform Pants Length", value: "\(settings.uniformPantsLength) in")
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: "Loadout Weight", selection: $settings.loadoutWeight,
                    values: Array(stride(from: 10, through: 150, by: 5)),
                    valueLabel: { "\($0) lbs" }
                )
            } label: {
                LabeledContent("Loadout Weight", value: "\(settings.loadoutWeight) lbs")
            }
        }
        .navigationTitle("Gait Tracking")
    }
}

private struct NetworkPreferencesView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var sitxClient: SitxClient

    var body: some View {
        List {
            NavigationLink {
                RelayProviderView(settings: settings)
            } label: {
                Text("TAK Relay (\(settings.relayProvider.rawValue))")
            }
            NavigationLink {
                SitxDeviceAPIView(settings: settings, client: sitxClient)
            } label: {
                Text("Sit(x) Device API")
            }
        }
        .navigationTitle("Network Preferences")
    }
}

private struct RelayProviderView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(RelayProvider.allCases) { provider in
            Button {
                settings.relayProvider = provider
                dismiss()
            } label: {
                HStack {
                    Text(provider.rawValue)
                    Spacer()
                    if settings.relayProvider == provider {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        .navigationTitle("TAK Relay")
    }
}

private struct SitxDeviceAPIView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var client: SitxClient
    @State private var confirmForget = false

    var body: some View {
        List {
            TextField("Sit(x) Host", text: $settings.sitxApiHost)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Button {
                    client.refreshAuthorizationCode()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auth Code")
                        Text(client.authorizationCode.isEmpty ? "Tap to refresh" : client.authorizationCode)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !client.verificationURL.isEmpty, let url = URL(string: client.verificationURL) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .accessibilityLabel("Open authorization page")
                }
            }
            LabeledContent("Status", value: client.status)
            Button("Clear Sit(x)", role: .destructive) {
                confirmForget = true
            }
        }
        .navigationTitle("Sit(x) Device API")
        .confirmationDialog("Clear Sit(x)?", isPresented: $confirmForget) {
            Button("Clear Sit(x)", role: .destructive) {
                client.forgetAuthorization()
            }
        }
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
