import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var settings: AppSettings
    @ObservedObject private var sitxClient: SitxClient

    init(model: WatchSessionModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        _sitxClient = ObservedObject(wrappedValue: model.sitxClient)
    }

    private var versionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let revision = Bundle.main.infoDictionary?["WearTAKGitCommit"] as? String ?? "unknown"
        return "\(version)-\(revision)"
    }

    var body: some View {
        List {
            NavigationLink("Callsign and Device Preferences") {
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
            Text("Version \(versionLabel)")
                .foregroundStyle(.secondary)
        }
        .navigationTitle("Settings")
    }
}

private struct DevicePreferencesView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Section {
                NavigationLink {
                    MyCallsignView(settings: settings)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("My Callsign")
                        Text(settings.callSign.isEmpty ? "Not Set" : settings.callSign)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    MyTeamView(settings: settings)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("My Team")
                            Text(settings.teamColor.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle()
                            .fill(settings.teamColor.swatchColor)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.gray.opacity(0.7), lineWidth: 1))
                    }
                }
                NavigationLink {
                    MyRoleView(settings: settings)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("My Role")
                        Text(settings.roleGroup.map { "\($0.rawValue) · \(settings.role)" } ?? "Not Set")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink("My User Metrics") {
                    UserMetricsView(settings: settings)
                }
            }
            Section {
                NavigationLink {
                    ReportingStrategyView(settings: settings)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reporting Strategy")
                        Text(settings.reportingStrategy.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    WiFiBatteryPreferencesView(settings: settings)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save Battery on WiFi")
                        Text(settings.wifiBatteryPolicy.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Physiological Monitoring", isOn: $settings.physiologicalMonitoringEnabled)
            }
        }
        .navigationTitle("Callsign and Device Preferences")
    }
}

private struct WiFiBatteryPreferencesView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            ForEach(WiFiBatteryPolicy.allCases) { policy in
                Button {
                    settings.wifiBatteryPolicy = policy
                } label: {
                    HStack {
                        Text(policy.rawValue)
                        Spacer()
                        if settings.wifiBatteryPolicy == policy {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(policy == .some)
                .accessibilityHint(policy == .some ? "WiFi network names are unavailable on watchOS" : "")
            }
        }
        .navigationTitle("Save Battery on WiFi")
    }
}

private struct ReportingStrategyView: View {
    @ObservedObject var settings: AppSettings

    private let commonIntervals = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]

    var body: some View {
        List {
            Section("Strategy") {
                ForEach(ReportingStrategy.allCases) { strategy in
                    Button {
                        settings.reportingStrategy = strategy
                    } label: {
                        HStack {
                            Text(strategy.rawValue)
                            Spacer()
                            if settings.reportingStrategy == strategy {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            if settings.reportingStrategy == .dynamic {
                Section("Dynamic Intervals") {
                    intervalRow("Stationary Reporting Interval", value: $settings.stationaryReportingInterval)
                    intervalRow("On Foot Reporting Interval", value: $settings.onFootReportingInterval)
                    intervalRow("Vehicle Reporting Interval", value: $settings.vehicleReportingInterval)
                    intervalRow("While Alerting Reporting Interval", value: $settings.alertingReportingInterval)
                }
            } else {
                Section("Constant Interval") {
                    intervalRow("Reporting Interval", value: $settings.constantReportingInterval)
                }
            }
        }
        .navigationTitle("Reporting Strategy")
    }

    private func intervalRow(_ title: String, value: Binding<Int>) -> some View {
        NavigationLink {
            ProfileNumberPickerView(
                title: title,
                selection: value,
                values: commonIntervals,
                valueLabel: { "\($0) seconds" }
            )
        } label: {
            LabeledContent(title, value: "\(value.wrappedValue) seconds")
        }
    }
}

private struct MyCallsignView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            TextField("Callsign", text: $settings.callSign)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
        }
        .navigationTitle("My Callsign")
    }
}

private struct MyTeamView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(TeamColor.allCases) { color in
            Button {
                settings.teamColor = color
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(color.swatchColor)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(.gray.opacity(0.7), lineWidth: 1))
                    Text(color.rawValue)
                    Spacer()
                    if settings.teamColor == color {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        .navigationTitle("My Team")
    }
}

private extension TeamColor {
    var swatchColor: Color {
        switch self {
        case .white: return .white
        case .yellow: return .yellow
        case .orange: return .orange
        case .magenta: return Color(red: 1, green: 0, blue: 1)
        case .red: return .red
        case .maroon: return Color(red: 0.5, green: 0, blue: 0)
        case .purple: return .purple
        case .darkBlue: return Color(red: 0, green: 0.15, blue: 0.45)
        case .blue: return .blue
        case .cyan: return .cyan
        case .teal: return .teal
        case .green: return .green
        case .darkGreen: return Color(red: 0, green: 0.35, blue: 0.12)
        case .brown: return .brown
        }
    }
}

private struct MyRoleView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var selectedGroup: UserRoleGroup?

    var body: some View {
        List {
            Section("Role Group") {
                ForEach(UserRoleGroup.allCases) { group in
                    Button {
                        selectedGroup = group
                    } label: {
                        HStack {
                            Text(group.rawValue)
                            Spacer()
                            if selectedGroup == group || settings.roleGroup == group {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            if let selectedGroup {
                Section(selectedGroup.rawValue) {
                    ForEach(selectedGroup.roles, id: \.self) { role in
                        Button {
                            settings.roleGroup = selectedGroup
                            settings.role = role
                            dismiss()
                        } label: {
                            HStack {
                                Text(role)
                                Spacer()
                                if settings.roleGroup == selectedGroup && settings.role == role {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("My Role")
        .onAppear { selectedGroup = settings.roleGroup }
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
                Text(sitxClient.menuLabel)
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
            LabeledContent("Pending Events", value: "\(client.pendingEvents.count)")
            if !client.groups.isEmpty {
                NavigationLink {
                    List(client.groups) { group in
                        Button {
                            client.selectGroup(group)
                        } label: {
                            HStack {
                                Text(group.name)
                                Spacer()
                                if client.selectedGroupID == group.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    .navigationTitle("TAK Group")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TAK Group")
                        Text(client.groups.first { $0.id == client.selectedGroupID }?.name ?? "Not selected")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
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
            NavigationLink("Physiological Alerts") {
                PhysiologicalAlertsView(settings: settings)
            }
            NavigationLink("Environmental Alerts") {
                EnvironmentalAlertsView(settings: settings)
            }
            Toggle(isOn: $settings.batteryAlertsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Battery Alerts")
                    Text(settings.batteryAlertsEnabled ? "On (50%, 25%)" : "Off")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
            NavigationLink("Resting Heart Rate Alerts") {
                RestingHeartRateAlertsView(settings: settings)
            }
            NavigationLink("Exertion Alerts") {
                ExertionAlertsView(settings: settings)
            }
        }
        .navigationTitle("Physiological Alerts")
    }
}

private struct RestingHeartRateAlertsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Section("High Resting Heart Rate") {
                NavigationLink {
                    ProfileNumberPickerView(
                        title: "High HR Threshold", selection: $settings.highRestingHeartRate,
                        values: Array(stride(from: 80, through: 200, by: 5)), valueLabel: { "\($0) bpm" }
                    )
                } label: {
                    LabeledContent("High HR Threshold", value: "\(settings.highRestingHeartRate) bpm")
                }
                NavigationLink {
                    ProfileNumberPickerView(
                        title: "Warning Length", selection: $settings.highRestingWarningMinutes,
                        values: Array(1...60), valueLabel: { "\($0) minutes" }
                    )
                } label: {
                    LabeledContent("Warning Length", value: "\(settings.highRestingWarningMinutes) minutes")
                }
                NavigationLink {
                    ProfileNumberPickerView(
                        title: "Alert Length", selection: $settings.highRestingAlertMinutes,
                        values: Array(1...60), valueLabel: { "\($0) minutes" }
                    )
                } label: {
                    LabeledContent("Alert Length", value: "\(settings.highRestingAlertMinutes) minutes")
                }
            }
            Section("Low Resting Heart Rate") {
                NavigationLink {
                    ProfileNumberPickerView(
                        title: "Low HR Threshold", selection: $settings.lowRestingHeartRate,
                        values: Array(stride(from: 25, through: 100, by: 5)), valueLabel: { "\($0) bpm" }
                    )
                } label: {
                    LabeledContent("Low HR Threshold", value: "\(settings.lowRestingHeartRate) bpm")
                }
                NavigationLink {
                    ProfileNumberPickerView(
                        title: "Warning Length", selection: $settings.lowRestingWarningMinutes,
                        values: Array(1...60), valueLabel: { "\($0) minutes" }
                    )
                } label: {
                    LabeledContent("Warning Length", value: "\(settings.lowRestingWarningMinutes) minutes")
                }
                NavigationLink {
                    ProfileNumberPickerView(
                        title: "Alert Length", selection: $settings.lowRestingAlertMinutes,
                        values: Array(1...60), valueLabel: { "\($0) minutes" }
                    )
                } label: {
                    LabeledContent("Alert Length", value: "\(settings.lowRestingAlertMinutes) minutes")
                }
            }
        }
        .navigationTitle("Resting Heart Rate Alerts")
    }
}

private struct ExertionAlertsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            NavigationLink {
                ProfileNumberPickerView(
                    title: "Warning Threshold", selection: $settings.exertionWarningThreshold,
                    values: Array(stride(from: 50, through: 100, by: 5)), valueLabel: { "\($0)%" }
                )
            } label: {
                LabeledContent("Warning Threshold", value: "\(settings.exertionWarningThreshold)%")
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: "Warning Length", selection: $settings.exertionWarningLengthSeconds,
                    values: Array(stride(from: 30, through: 600, by: 30)), valueLabel: { "\($0) seconds" }
                )
            } label: {
                LabeledContent("Warning Length", value: "\(settings.exertionWarningLengthSeconds) seconds")
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: "Alert Threshold", selection: $settings.exertionAlertThreshold,
                    values: Array(stride(from: 50, through: 100, by: 5)), valueLabel: { "\($0)%" }
                )
            } label: {
                LabeledContent("Alert Threshold", value: "\(settings.exertionAlertThreshold)%")
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: "Alert Length", selection: $settings.exertionAlertLengthSeconds,
                    values: Array(stride(from: 30, through: 600, by: 30)), valueLabel: { "\($0) seconds" }
                )
            } label: {
                LabeledContent("Alert Length", value: "\(settings.exertionAlertLengthSeconds) seconds")
            }
        }
        .navigationTitle("Exertion Alerts")
    }
}

private struct EnvironmentalAlertsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Toggle(isOn: $settings.immersionAlertsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Immersion Alerts")
                    Text(settings.immersionAlertsEnabled ? "On" : "Off")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink("Atm Pressure Alerts") {
                AtmosphericPressureAlertsView(settings: settings)
            }
        }
        .navigationTitle("Environmental Alerts")
    }
}

private struct AtmosphericPressureAlertsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Toggle(isOn: $settings.lowPressureAlertsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Low Pressure Alert")
                    Text(settings.lowPressureAlertsEnabled ? "On" : "Off")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: "Pressure Threshold", selection: $settings.lowPressureThreshold,
                    values: Array(stride(from: 800, through: 1100, by: 5)), valueLabel: { "\($0) hPa" }
                )
            } label: {
                LabeledContent("Pressure Threshold", value: "\(settings.lowPressureThreshold) hPa")
            }
            Toggle(isOn: $settings.highPressureAlertsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("High Pressure Alert")
                    Text(settings.highPressureAlertsEnabled ? "On" : "Off")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: "Pressure Threshold", selection: $settings.highPressureThreshold,
                    values: Array(stride(from: 1000, through: 1100, by: 5)), valueLabel: { "\($0) hPa" }
                )
            } label: {
                LabeledContent("Pressure Threshold", value: "\(settings.highPressureThreshold) hPa")
            }
        }
        .navigationTitle("Atm Pressure Alerts")
    }
}

private struct ToolPreferencesView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Toggle(isOn: $settings.chatEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chat")
                    Text(settings.chatEnabled ? "On" : "Off")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink("Navigation") {
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
            Toggle(isOn: $settings.bloodhoundProximityVibrationEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bloodhound Proximity Vibration")
                    Text(settings.bloodhoundProximityVibrationEnabled ? "On" : "Off")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: "Bloodhound Proximity Radius", selection: $settings.bloodhoundProximityRadius,
                    values: Array(stride(from: 10, through: 200, by: 10)), valueLabel: { "\($0) meters" }
                )
            } label: {
                LabeledContent("Bloodhound Proximity Radius", value: "\(settings.bloodhoundProximityRadius) meters")
            }
            NavigationLink {
                ProfileStringPickerView(
                    title: "Bloodhound Proximity Intensity", selection: $settings.bloodhoundProximityIntensity,
                    values: AppSettings.bloodhoundProximityIntensityOptions
                )
            } label: {
                LabeledContent("Bloodhound Proximity Intensity", value: settings.bloodhoundProximityIntensity)
            }
        }
        .navigationTitle("Navigation")
    }
}
