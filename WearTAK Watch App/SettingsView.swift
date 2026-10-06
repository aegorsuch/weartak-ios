import SwiftUI
import OSLog

struct SettingsView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var settings: AppSettings
    @ObservedObject private var sitxClient: SitxClient
    @State private var showDeveloperModeEnabled = false

    init(model: WatchSessionModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        _sitxClient = ObservedObject(wrappedValue: model.sitxClient)
    }

    private var versionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        return "\(version) (\(build))" + (Self.revision.map { " - \($0)" } ?? "")
    }

    private static let revision: String? = {
        do {
            guard let url = Bundle.main.url(forResource: "WearTAKGitCommit", withExtension: "txt") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            Logger(subsystem: "com.aegorsuch.weartak", category: "Build").error("Cannot read build revision: \(error.localizedDescription)")
            return nil
        }
    }()

    var body: some View {
        List {
            NavigationLink(String(localized: "Callsign and Device Preferences", table: "WatchSettings")) {
                DevicePreferencesView(settings: settings)
            }
            NavigationLink(String(localized: "Network Preferences", table: "WatchSettings")) {
                NetworkPreferencesView(model: model, settings: settings, sitxClient: sitxClient)
            }
            NavigationLink(String(localized: "Alerting Preferences", table: "WatchSettings")) {
                AlertingPreferencesView(settings: settings)
            }
            NavigationLink(String(localized: "Tool Preferences", table: "WatchSettings")) {
                ToolPreferencesView(model: model, settings: settings)
            }
            Button {
                showDeveloperModeEnabled = settings.registerVersionTap()
            } label: {
                Text(String(localized: "Version \(versionLabel)", table: "WatchSettings"))
                    .foregroundStyle(.secondary)
            }
            if settings.developerMode {
                Toggle(String(localized: "Developer mode", table: "WatchSettings"), isOn: $settings.developerMode)
            }
        }
        .navigationTitle(String(localized: "Settings", table: "WatchSettings"))
        .onDisappear { settings.resetVersionTaps() }
        .alert(String(localized: "Developer mode enabled", table: "WatchSettings"), isPresented: $showDeveloperModeEnabled) {
            Button(String(localized: "OK", table: "WatchSettings"), role: .cancel) {}
        }
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
                        Text(String(localized: "My Callsign", table: "WatchSettings"))
                        Text(settings.callSign.isEmpty ? String(localized: "Not Set", table: "WatchSettings") : settings.callSign)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    MyTeamView(settings: settings)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "My Team", table: "WatchSettings"))
                            Text(settings.teamColor.localizedName)
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
                        Text(String(localized: "My Role", table: "WatchSettings"))
                        Text(settings.roleGroup.map { "\($0.localizedName) · \(AppSettings.localizedOption(settings.role))" } ?? String(localized: "Not Set", table: "WatchSettings"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink(String(localized: "My User Metrics", table: "WatchSettings")) {
                    UserMetricsView(settings: settings)
                }
            }
            Section {
                NavigationLink {
                    ReportingStrategyView(settings: settings)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Reporting Strategy", table: "WatchSettings"))
                        Text(settings.reportingStrategy.localizedName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                NavigationLink {
                    WiFiBatteryPreferencesView(settings: settings)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "Save Battery on WiFi", table: "WatchSettings"))
                        Text(settings.wifiBatteryPolicy.localizedName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(String(localized: "Physiological Monitoring", table: "WatchSettings"), isOn: $settings.physiologicalMonitoringEnabled)
            }
        }
        .navigationTitle(String(localized: "Callsign and Device Preferences", table: "WatchSettings"))
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
                        Text(policy.localizedName)
                        Spacer()
                        if settings.wifiBatteryPolicy == policy {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(policy == .some)
                .accessibilityHint(policy == .some ? String(localized: "WiFi network names are unavailable on watchOS", table: "WatchSettings") : "")
            }
        }
        .navigationTitle(String(localized: "Save Battery on WiFi", table: "WatchSettings"))
    }
}

struct ReportingStrategyView: View {
    @ObservedObject var settings: AppSettings

    private let commonIntervals = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]

    var body: some View {
        List {
            Section(String(localized: "Strategy", table: "WatchSettings")) {
                ForEach(ReportingStrategy.allCases) { strategy in
                    Button {
                        settings.reportingStrategy = strategy
                    } label: {
                        HStack {
                            Text(strategy.localizedName)
                            Spacer()
                            if settings.reportingStrategy == strategy {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            if settings.reportingStrategy == .dynamic {
                Section(String(localized: "Dynamic Intervals", table: "WatchSettings")) {
                    intervalRow(String(localized: "Stationary Reporting Interval", table: "WatchSettings"), value: $settings.stationaryReportingInterval)
                    intervalRow(String(localized: "On Foot Reporting Interval", table: "WatchSettings"), value: $settings.onFootReportingInterval)
                    intervalRow(String(localized: "Vehicle Reporting Interval", table: "WatchSettings"), value: $settings.vehicleReportingInterval)
                    intervalRow(String(localized: "While Alerting Reporting Interval", table: "WatchSettings"), value: $settings.alertingReportingInterval)
                }
            } else {
                Section(String(localized: "Constant Interval", table: "WatchSettings")) {
                    intervalRow(String(localized: "Reporting Interval", table: "WatchSettings"), value: $settings.constantReportingInterval)
                }
            }
        }
        .navigationTitle(String(localized: "Reporting Strategy", table: "WatchSettings"))
    }

    private func intervalRow(_ title: String, value: Binding<Int>) -> some View {
        NavigationLink {
            ProfileNumberPickerView(
                title: title,
                selection: value,
                values: commonIntervals,
                valueLabel: { String(localized: "\($0) seconds", table: "WatchSettings") }
            )
        } label: {
            LabeledContent(title, value: String(localized: "\(value.wrappedValue) seconds", table: "WatchSettings"))
        }
    }
}

private struct MyCallsignView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            TextField(String(localized: "Callsign", table: "WatchSettings"), text: $settings.callSign)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
        }
        .navigationTitle(String(localized: "My Callsign", table: "WatchSettings"))
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
                    Text(color.localizedName)
                    Spacer()
                    if settings.teamColor == color {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        .navigationTitle(String(localized: "My Team", table: "WatchSettings"))
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
            Section(String(localized: "Role Group", table: "WatchSettings")) {
                ForEach(UserRoleGroup.allCases) { group in
                    Button {
                        selectedGroup = group
                    } label: {
                        HStack {
                            Text(group.localizedName)
                            Spacer()
                            if selectedGroup == group || settings.roleGroup == group {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            if let selectedGroup {
                Section(selectedGroup.localizedName) {
                    ForEach(selectedGroup.roles, id: \.self) { role in
                        Button {
                            settings.roleGroup = selectedGroup
                            settings.role = role
                            dismiss()
                        } label: {
                            HStack {
                                Text(AppSettings.localizedOption(role))
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
        .navigationTitle(String(localized: "My Role", table: "WatchSettings"))
        .onAppear { selectedGroup = settings.roleGroup }
    }
}

private struct UserMetricsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            NavigationLink(String(localized: "Medical Profile (BATDOK)", table: "WatchSettings")) {
                MedicalProfileView(settings: settings)
            }
            NavigationLink(String(localized: "Gait Tracking", table: "WatchSettings")) {
                GaitTrackingView(settings: settings)
            }
        }
        .navigationTitle(String(localized: "My User Metrics", table: "WatchSettings"))
    }
}

private struct MedicalProfileView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            NavigationLink {
                ProfileNumberPickerView(
                    title: String(localized: "Birth Year", table: "WatchSettings"), selection: $settings.birthYear,
                    values: Array(1920...Calendar.current.component(.year, from: Date())),
                    valueLabel: { "\($0)" }
                )
            } label: {
                LabeledContent(String(localized: "Birth Year", table: "WatchSettings"), value: "\(settings.birthYear)")
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: String(localized: "Height", table: "WatchSettings"), selection: $settings.heightInches,
                    values: Array(48...84),
                    valueLabel: { "\($0 / 12)' \($0 % 12)\u{22}" }
                )
            } label: {
                LabeledContent(String(localized: "Height", table: "WatchSettings"), value: "\(settings.heightInches / 12)' \(settings.heightInches % 12)\u{22}")
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: String(localized: "Weight", table: "WatchSettings"), selection: $settings.weightPounds,
                    values: Array(stride(from: 80, through: 320, by: 5)),
                    valueLabel: { String(localized: "\($0) lb", table: "WatchSettings") }
                )
            } label: {
                LabeledContent(String(localized: "Weight", table: "WatchSettings"), value: String(localized: "\(settings.weightPounds) lb", table: "WatchSettings"))
            }
            NavigationLink {
                ProfileStringPickerView(title: String(localized: "Sex", table: "WatchSettings"), selection: $settings.sex, values: AppSettings.sexOptions)
            } label: {
                LabeledContent(String(localized: "Sex", table: "WatchSettings"), value: AppSettings.localizedOption(settings.sex))
            }
            NavigationLink {
                ProfileStringPickerView(title: String(localized: "Blood Type", table: "WatchSettings"), selection: $settings.bloodType, values: AppSettings.bloodTypeOptions)
            } label: {
                LabeledContent(String(localized: "Blood Type", table: "WatchSettings"), value: AppSettings.localizedOption(settings.bloodType))
            }
            NavigationLink {
                AllergiesView(settings: settings)
            } label: {
                LabeledContent(String(localized: "Allergies", table: "WatchSettings"), value: settings.allergies.map(AppSettings.localizedOption).joined(separator: ", "))
            }
            NavigationLink {
                ProfileStringPickerView(title: String(localized: "User Type", table: "WatchSettings"), selection: $settings.userType, values: AppSettings.userTypeOptions)
            } label: {
                LabeledContent(String(localized: "User Type", table: "WatchSettings"), value: AppSettings.localizedOption(settings.userType))
            }
        }
        .navigationTitle(String(localized: "Medical Profile (BATDOK)", table: "WatchSettings"))
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
                    Text(AppSettings.localizedOption(value))
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
                    Text(AppSettings.localizedOption(allergy))
                    Spacer()
                    if settings.allergies.contains(allergy) {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Allergies", table: "WatchSettings"))
    }
}

private struct GaitTrackingView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            NavigationLink {
                ProfileNumberPickerView(
                    title: String(localized: "Uniform Waist Size", table: "WatchSettings"), selection: $settings.uniformWaistSize,
                    values: Array(24...60), valueLabel: { String(localized: "\($0) in", table: "WatchSettings") }
                )
            } label: {
                LabeledContent(String(localized: "Uniform Waist Size", table: "WatchSettings"), value: String(localized: "\(settings.uniformWaistSize) in", table: "WatchSettings"))
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: String(localized: "Stride Length", table: "WatchSettings"), selection: $settings.strideLength,
                    values: Array(20...45), valueLabel: { String(localized: "\($0) in", table: "WatchSettings") }
                )
            } label: {
                LabeledContent(String(localized: "Stride Length", table: "WatchSettings"), value: String(localized: "\(settings.strideLength) in", table: "WatchSettings"))
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: String(localized: "Uniform Pants Length", table: "WatchSettings"), selection: $settings.uniformPantsLength,
                    values: Array(24...60), valueLabel: { String(localized: "\($0) in", table: "WatchSettings") }
                )
            } label: {
                LabeledContent(String(localized: "Uniform Pants Length", table: "WatchSettings"), value: String(localized: "\(settings.uniformPantsLength) in", table: "WatchSettings"))
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: String(localized: "Loadout Weight", table: "WatchSettings"), selection: $settings.loadoutWeight,
                    values: Array(stride(from: 10, through: 150, by: 5)),
                    valueLabel: { String(localized: "\($0) lbs", table: "WatchSettings") }
                )
            } label: {
                LabeledContent(String(localized: "Loadout Weight", table: "WatchSettings"), value: String(localized: "\(settings.loadoutWeight) lbs", table: "WatchSettings"))
            }
        }
        .navigationTitle(String(localized: "Gait Tracking", table: "WatchSettings"))
    }
}

struct NetworkPreferencesView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var sitxClient: SitxClient

    var body: some View {
        List {
            NavigationLink {
                RelayProviderView(model: model, settings: settings)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "TAK Relay (\(settings.relayProvider.localizedName))", table: "WatchSettings", comment: "Settings row. The argument is the selected relay provider name."))
                    if settings.relayProvider == .companion {
                        CompanionLinkCaption(client: model.companionClient)
                    }
                }
            }
            NavigationLink {
                MulticastPreferencesView(settings: settings, client: model.multicastClient, model: model)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TAK SA Multicast")
                    Text(settings.multicastEnabled ? String(localized: "Enabled", table: "WatchSettings") : String(localized: "Disabled", table: "WatchSettings"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                SitxDeviceAPIView(settings: settings, client: sitxClient)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sit(x) TAK")
                    Text(WatchSettingsStatusText.sitx(sitxClient.status))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(String(localized: "Network Preferences", table: "WatchSettings"))
    }
}

private struct CompanionLinkCaption: View {
    @ObservedObject var client: WatchCompanionOutput

    var body: some View {
        Text(client.linkState.label)
            .font(.caption2)
            .foregroundStyle(client.linkState == .connected ? Color.secondary
                : client.linkState == .disconnected ? Color.red : Color.orange)
    }
}

private struct MulticastPreferencesView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var client: MulticastTAKTransport
    @ObservedObject var model: WatchSessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Toggle("TAK SA Multicast", isOn: $settings.multicastEnabled)
                .disabled(!AppSettings.isMulticastAddress(settings.multicastAddress))
            NavigationLink {
                MulticastAddressView(settings: settings)
            } label: {
                LabeledContent(String(localized: "Address", table: "WatchSettings"), value: settings.multicastAddress)
            }
            Picker(String(localized: "Output Protocol", table: "WatchSettings"), selection: $settings.multicastOutputProtocol) {
                ForEach(MulticastOutputProtocol.allCases) { output in
                    Text(output.rawValue).tag(output)
                }
            }
            NavigationLink {
                MulticastPortView(settings: settings)
            } label: {
                LabeledContent(String(localized: "Port", table: "WatchSettings"), value: "\(settings.multicastPort)")
            }
            Button { dismiss() } label: {
                Label(String(localized: "Back", table: "WatchSettings"), systemImage: "arrow.left")
            }
            if settings.developerMode {
                Section(String(localized: "Runtime Status", table: "WatchSettings")) {
                    Text(WatchSettingsStatusText.multicast(client.status))
                        .foregroundStyle(client.isReady ? .green : .orange)
                    LabeledContent(String(localized: "Datagrams sent", table: "WatchSettings"), value: "\(client.sentDatagrams)")
                    LabeledContent(String(localized: "Datagrams received", table: "WatchSettings"), value: "\(client.receivedDatagrams)")
                    if let date = client.lastSentAt {
                        LabeledContent(String(localized: "Last local send", table: "WatchSettings")) { Text(date, style: .time) }
                    }
                    if let error = client.lastSendError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    LabeledContent(String(localized: "Stored events", table: "WatchSettings"), value: "\(model.queuedEventCount)")
                    Toggle(String(localized: "Developer mode", table: "WatchSettings"), isOn: $settings.developerMode)
                }
            }
        }
        .navigationTitle("TAK SA Multicast")
        .navigationBarBackButtonHidden(true)
    }
}

private struct MulticastAddressView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var address: String

    init(settings: AppSettings) {
        self.settings = settings
        _address = State(initialValue: settings.multicastAddress)
    }

    var body: some View {
        List {
            TextField(String(localized: "Multicast IPv4", table: "WatchSettings"), text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(save)
            Button(action: save) { Label(String(localized: "Save", table: "WatchSettings"), systemImage: "checkmark") }
                .disabled(!AppSettings.isMulticastAddress(address))
        }
        .navigationTitle(String(localized: "Address", table: "WatchSettings"))
    }

    private func save() {
        guard AppSettings.isMulticastAddress(address) else { return }
        settings.multicastAddress = address
        dismiss()
    }
}

private struct MulticastPortView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var port: String

    init(settings: AppSettings) {
        self.settings = settings
        _port = State(initialValue: String(settings.multicastPort))
    }

    var body: some View {
        List {
            TextField(String(localized: "Port", table: "WatchSettings"), text: $port).onSubmit(save)
            Button(action: save) { Label(String(localized: "Save", table: "WatchSettings"), systemImage: "checkmark") }
                .disabled(Int(port).map { !(1...65535).contains($0) } ?? true)
        }
        .navigationTitle(String(localized: "Port", table: "WatchSettings"))
    }

    private func save() {
        guard let number = Int(port), (1...65535).contains(number) else { return }
        settings.multicastPort = number
        dismiss()
    }
}

private struct RelayProviderView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(RelayProvider.allCases) { provider in
                Button {
                    settings.relayProvider = provider
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(provider.localizedName)
                                if provider == .itak || provider == .takAwareRelay {
                                    Text(String(localized: "Teaming", table: "WatchSettings"))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if provider == .companion && !model.companionServerConfigured {
                                Text(String(localized: "Configure on phone", table: "WatchSettings"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if settings.relayProvider == provider {
                            Image(systemName: "checkmark")
                        }
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
    @Environment(\.dismiss) private var dismiss
    @State private var showAuthorization = false
    @State private var confirmRemoval = false
    @State private var removing = false
    @State private var removalError: String?

    private var settingsList: some View {
        List {
            if let phone = client.phoneManagedSettings {
                Toggle("Sit(x) TAK", isOn: .constant(phone.enabled))
                    .disabled(true)
                LabeledContent(String(localized: "Address", table: "WatchSettings"), value: phone.host.replacingOccurrences(of: "https://", with: ""))
                LabeledContent(String(localized: "Group", table: "WatchSettings"), value: phone.groupName ?? String(localized: "Not selected", table: "WatchSettings"))
                LabeledContent(String(localized: "Sit(x) State", table: "WatchSettings"), value: client.canReachPhone ? WatchSettingsStatusText.sitx(phone.status) : String(localized: "Needs iPhone", table: "WatchSettings"))
                Text(String(localized: "Managed in Companion", table: "WatchSettings"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                watchSettings
            }
            Button {
                dismiss()
            } label: {
                Label(String(localized: "Back", table: "WatchSettings"), systemImage: "arrow.left")
            }
            Button(String(localized: "Remove Sit(x) connection", table: "WatchSettings"), role: .destructive) { confirmRemoval = true }
        }
    }

    private var watchSettings: some View {
        Group {
            Toggle("Sit(x) TAK", isOn: Binding(
                get: { settings.sitxEnabled },
                set: { client.setTAKEnabled($0) }
            ))
            NavigationLink {
                SitxAddressView(settings: settings, client: client)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Address", table: "WatchSettings"))
                    Text(settings.sitxApiHost.isEmpty ? String(localized: "Not set", table: "WatchSettings") : settings.sitxApiHost.replacingOccurrences(of: "https://", with: ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
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
                .navigationTitle(String(localized: "Group", table: "WatchSettings"))
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Group", table: "WatchSettings"))
                    Text(client.groups.first { $0.id == client.selectedGroupID }?.name ?? String(localized: "Not selected", table: "WatchSettings"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(client.groups.isEmpty || !settings.sitxEnabled)
            LabeledContent(String(localized: "Sit(x) State", table: "WatchSettings"), value: WatchSettingsStatusText.sitx(client.status))
            Button {
                client.refreshAuthorizationCode()
            } label: {
                Label(String(localized: "Re-auth", table: "WatchSettings"), systemImage: "arrow.clockwise")
            }
            .disabled(!settings.sitxEnabled || settings.sitxApiHost.isEmpty)
        }
    }

    var body: some View {
        settingsList
        .navigationTitle("Sit(x) TAK")
        .disabled(removing)
        .confirmationDialog(String(localized: "Remove Sit(x) connection and all saved authorization, address and groups?", table: "WatchSettings"), isPresented: $confirmRemoval) {
            Button(String(localized: "Remove Sit(x) connection", table: "WatchSettings"), role: .destructive) {
                removing = true
                Task {
                    defer { removing = false }
                    do { try await client.removeConnection() }
                    catch { removalError = error.localizedDescription }
                }
            }
        }
        .alert(String(localized: "Sit(x) removal failed", table: "WatchSettings"), isPresented: Binding(
            get: { removalError != nil }, set: { if !$0 { removalError = nil } }
        )) {
            Button(String(localized: "OK", table: "WatchSettings"), role: .cancel) { removalError = nil }
        } message: { Text(removalError ?? "") }
        .navigationBarBackButtonHidden(true)
        .onAppear { showAuthorization = !client.authorizationCode.isEmpty }
        .onChange(of: client.authorizationCode) { _, code in
            showAuthorization = !code.isEmpty
        }
        .sheet(isPresented: $showAuthorization) {
            NavigationStack {
                List {
                    LabeledContent(String(localized: "Auth Code", table: "WatchSettings"), value: client.authorizationCode)
                    if let url = URL(string: client.verificationURL), !client.verificationURL.isEmpty {
                        Link(destination: url) {
                            Label(String(localized: "Authorize", table: "WatchSettings"), systemImage: "arrow.up.right.square")
                        }
                    }
                    Text(WatchSettingsStatusText.sitx(client.status))
                    Button {
                        showAuthorization = false
                    } label: {
                        Label(String(localized: "Back", table: "WatchSettings"), systemImage: "arrow.left")
                    }
                }
                .navigationTitle(String(localized: "Authorization", table: "WatchSettings"))
            }
        }
    }
}

private struct SitxAddressView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var client: SitxClient
    @Environment(\.dismiss) private var dismiss
    @State private var address: String

    init(settings: AppSettings, client: SitxClient) {
        self.settings = settings
        self.client = client
        var organization = settings.sitxApiHost.replacingOccurrences(of: "https://", with: "")
        if organization.hasSuffix(".sitx.io") { organization.removeLast(".sitx.io".count) }
        _address = State(initialValue: organization)
    }

    var body: some View {
        List {
            TextField(String(localized: "Organization", table: "WatchSettings"), text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(saveAddress)
            Text(SitxClient.normalizedHost(address)?.replacingOccurrences(of: "https://", with: "") ?? ".sitx.io")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button(action: saveAddress) {
                Label(String(localized: "Save", table: "WatchSettings"), systemImage: "checkmark")
            }
            .disabled(SitxClient.normalizedHost(address) == nil)
        }
        .navigationTitle(String(localized: "Address", table: "WatchSettings"))
    }

    private func saveAddress() {
        guard let host = SitxClient.normalizedHost(address) else { return }
        let changed = settings.sitxApiHost != host
        settings.sitxApiHost = host
        if settings.sitxEnabled, changed { client.setTAKEnabled(true) }
        dismiss()
    }
}

private struct AlertingPreferencesView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            NavigationLink(String(localized: "Physiological Alerts", table: "WatchSettings")) {
                PhysiologicalAlertsView(settings: settings)
            }
            NavigationLink(String(localized: "Environmental Alerts", table: "WatchSettings")) {
                EnvironmentalAlertsView(settings: settings)
            }
            Toggle(isOn: $settings.batteryAlertsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Battery Alerts", table: "WatchSettings"))
                    Text(settings.batteryAlertsEnabled ? String(localized: "On (\(50)%, \(25)%)", table: "WatchSettings") : String(localized: "Off", table: "WatchSettings"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(String(localized: "Alerting Preferences", table: "WatchSettings"))
    }
}

private struct PhysiologicalAlertsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Toggle(String(localized: "Physiological Alerts", table: "WatchSettings"), isOn: $settings.physiologicalAlertsEnabled)
            NavigationLink(String(localized: "Resting Heart Rate Alerts", table: "WatchSettings")) {
                RestingHeartRateAlertsView(settings: settings)
            }
            NavigationLink(String(localized: "Exertion Alerts", table: "WatchSettings")) {
                ExertionAlertsView(settings: settings)
            }
        }
        .navigationTitle(String(localized: "Physiological Alerts", table: "WatchSettings"))
    }
}

private struct RestingHeartRateAlertsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Section(String(localized: "High Resting Heart Rate", table: "WatchSettings")) {
                NavigationLink {
                    ProfileNumberPickerView(
                        title: String(localized: "High HR Threshold", table: "WatchSettings"), selection: $settings.highRestingHeartRate,
                        values: Array(stride(from: 80, through: 200, by: 5)), valueLabel: { String(localized: "\($0) bpm", table: "WatchSettings") }
                    )
                } label: {
                    LabeledContent(String(localized: "High HR Threshold", table: "WatchSettings"), value: String(localized: "\(settings.highRestingHeartRate) bpm", table: "WatchSettings"))
                }
                NavigationLink {
                    ProfileNumberPickerView(
                        title: String(localized: "Warning Length", table: "WatchSettings"), selection: $settings.highRestingWarningMinutes,
                        values: Array(1...60), valueLabel: { String(localized: "\($0) minutes", table: "WatchSettings") }
                    )
                } label: {
                    LabeledContent(String(localized: "Warning Length", table: "WatchSettings"), value: String(localized: "\(settings.highRestingWarningMinutes) minutes", table: "WatchSettings"))
                }
                NavigationLink {
                    ProfileNumberPickerView(
                        title: String(localized: "Alert Length", table: "WatchSettings"), selection: $settings.highRestingAlertMinutes,
                        values: Array(1...60), valueLabel: { String(localized: "\($0) minutes", table: "WatchSettings") }
                    )
                } label: {
                    LabeledContent(String(localized: "Alert Length", table: "WatchSettings"), value: String(localized: "\(settings.highRestingAlertMinutes) minutes", table: "WatchSettings"))
                }
            }
            Section(String(localized: "Low Resting Heart Rate", table: "WatchSettings")) {
                NavigationLink {
                    ProfileNumberPickerView(
                        title: String(localized: "Low HR Threshold", table: "WatchSettings"), selection: $settings.lowRestingHeartRate,
                        values: Array(stride(from: 25, through: 100, by: 5)), valueLabel: { String(localized: "\($0) bpm", table: "WatchSettings") }
                    )
                } label: {
                    LabeledContent(String(localized: "Low HR Threshold", table: "WatchSettings"), value: String(localized: "\(settings.lowRestingHeartRate) bpm", table: "WatchSettings"))
                }
                NavigationLink {
                    ProfileNumberPickerView(
                        title: String(localized: "Warning Length", table: "WatchSettings"), selection: $settings.lowRestingWarningMinutes,
                        values: Array(1...60), valueLabel: { String(localized: "\($0) minutes", table: "WatchSettings") }
                    )
                } label: {
                    LabeledContent(String(localized: "Warning Length", table: "WatchSettings"), value: String(localized: "\(settings.lowRestingWarningMinutes) minutes", table: "WatchSettings"))
                }
                NavigationLink {
                    ProfileNumberPickerView(
                        title: String(localized: "Alert Length", table: "WatchSettings"), selection: $settings.lowRestingAlertMinutes,
                        values: Array(1...60), valueLabel: { String(localized: "\($0) minutes", table: "WatchSettings") }
                    )
                } label: {
                    LabeledContent(String(localized: "Alert Length", table: "WatchSettings"), value: String(localized: "\(settings.lowRestingAlertMinutes) minutes", table: "WatchSettings"))
                }
            }
        }
        .navigationTitle(String(localized: "Resting Heart Rate Alerts", table: "WatchSettings"))
    }
}

private struct ExertionAlertsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            NavigationLink {
                ProfileNumberPickerView(
                    title: String(localized: "Warning Threshold", table: "WatchSettings"), selection: $settings.exertionWarningThreshold,
                    values: Array(stride(from: 50, through: 100, by: 5)), valueLabel: { "\($0)%" }
                )
            } label: {
                LabeledContent(String(localized: "Warning Threshold", table: "WatchSettings"), value: "\(settings.exertionWarningThreshold)%")
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: String(localized: "Warning Length", table: "WatchSettings"), selection: $settings.exertionWarningLengthSeconds,
                    values: Array(stride(from: 30, through: 600, by: 30)), valueLabel: { String(localized: "\($0) seconds", table: "WatchSettings") }
                )
            } label: {
                LabeledContent(String(localized: "Warning Length", table: "WatchSettings"), value: String(localized: "\(settings.exertionWarningLengthSeconds) seconds", table: "WatchSettings"))
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: String(localized: "Alert Threshold", table: "WatchSettings"), selection: $settings.exertionAlertThreshold,
                    values: Array(stride(from: 50, through: 100, by: 5)), valueLabel: { "\($0)%" }
                )
            } label: {
                LabeledContent(String(localized: "Alert Threshold", table: "WatchSettings"), value: "\(settings.exertionAlertThreshold)%")
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: String(localized: "Alert Length", table: "WatchSettings"), selection: $settings.exertionAlertLengthSeconds,
                    values: Array(stride(from: 30, through: 600, by: 30)), valueLabel: { String(localized: "\($0) seconds", table: "WatchSettings") }
                )
            } label: {
                LabeledContent(String(localized: "Alert Length", table: "WatchSettings"), value: String(localized: "\(settings.exertionAlertLengthSeconds) seconds", table: "WatchSettings"))
            }
        }
        .navigationTitle(String(localized: "Exertion Alerts", table: "WatchSettings"))
    }
}

private struct EnvironmentalAlertsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Toggle(isOn: $settings.immersionAlertsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Immersion Alerts", table: "WatchSettings"))
                    Text(settings.immersionAlertsEnabled ? String(localized: "On", table: "WatchSettings") : String(localized: "Off", table: "WatchSettings"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink(String(localized: "Atm Pressure Alerts", table: "WatchSettings")) {
                AtmosphericPressureAlertsView(settings: settings)
            }
        }
        .navigationTitle(String(localized: "Environmental Alerts", table: "WatchSettings"))
    }
}

private struct AtmosphericPressureAlertsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Toggle(isOn: $settings.lowPressureAlertsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Low Pressure Alert", table: "WatchSettings"))
                    Text(settings.lowPressureAlertsEnabled ? String(localized: "On", table: "WatchSettings") : String(localized: "Off", table: "WatchSettings"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: String(localized: "Pressure Threshold", table: "WatchSettings"), selection: $settings.lowPressureThreshold,
                    values: Array(stride(from: 800, through: 1100, by: 5)), valueLabel: { "\($0) hPa" }
                )
            } label: {
                LabeledContent(String(localized: "Pressure Threshold", table: "WatchSettings"), value: "\(settings.lowPressureThreshold) hPa")
            }
            Toggle(isOn: $settings.highPressureAlertsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "High Pressure Alert", table: "WatchSettings"))
                    Text(settings.highPressureAlertsEnabled ? String(localized: "On", table: "WatchSettings") : String(localized: "Off", table: "WatchSettings"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: String(localized: "Pressure Threshold", table: "WatchSettings"), selection: $settings.highPressureThreshold,
                    values: Array(stride(from: 1000, through: 1100, by: 5)), valueLabel: { "\($0) hPa" }
                )
            } label: {
                LabeledContent(String(localized: "Pressure Threshold", table: "WatchSettings"), value: "\(settings.highPressureThreshold) hPa")
            }
        }
        .navigationTitle(String(localized: "Atm Pressure Alerts", table: "WatchSettings"))
    }
}

private struct ToolPreferencesView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            NavigationLink("Bloodhound") {
                BloodhoundPreferencesView(settings: settings)
            }
            NavigationLink(String(localized: "Plugins", table: "WatchSettings")) {
                PluginsView(model: model, settings: settings)
            }
        }
        .navigationTitle(String(localized: "Tool Preferences", table: "WatchSettings"))
    }
}

private struct PluginsView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            NavigationLink {
                DataSyncMenuView(model: model, client: model.companionClient, settings: settings)
            } label: {
                Label("DataSync", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .navigationTitle(String(localized: "Plugins", table: "WatchSettings"))
    }
}

private struct BloodhoundPreferencesView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Toggle(isOn: $settings.bloodhoundProximityVibrationEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Bloodhound Proximity Vibration", table: "WatchSettings"))
                    Text(settings.bloodhoundProximityVibrationEnabled ? String(localized: "On", table: "WatchSettings") : String(localized: "Off", table: "WatchSettings"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink {
                ProfileNumberPickerView(
                    title: String(localized: "Bloodhound Proximity Radius", table: "WatchSettings"), selection: $settings.bloodhoundProximityRadius,
                    values: Array(stride(from: 10, through: 200, by: 10)), valueLabel: { String(localized: "\($0) meters", table: "WatchSettings") }
                )
            } label: {
                LabeledContent(String(localized: "Bloodhound Proximity Radius", table: "WatchSettings"), value: String(localized: "\(settings.bloodhoundProximityRadius) meters", table: "WatchSettings"))
            }
            NavigationLink {
                ProfileStringPickerView(
                    title: String(localized: "Bloodhound Proximity Intensity", table: "WatchSettings"), selection: $settings.bloodhoundProximityIntensity,
                    values: AppSettings.bloodhoundProximityIntensityOptions
                )
            } label: {
                LabeledContent(String(localized: "Bloodhound Proximity Intensity", table: "WatchSettings"), value: AppSettings.localizedOption(settings.bloodhoundProximityIntensity))
            }
        }
        .navigationTitle("Bloodhound")
    }
}
