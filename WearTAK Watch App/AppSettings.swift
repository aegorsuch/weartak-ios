import Combine
import Foundation
import Network

enum DashboardMetric: String, CaseIterable, Identifiable {
    case exertion = "Exertion"
    case heartRate = "Heart Rate"

    var id: Self { self }
    var symbol: String {
        self == .exertion ? "figure.strengthtraining.traditional" : "waveform.path.ecg"
    }
}

enum MulticastOutputProtocol: String, CaseIterable, Identifiable {
    case udp = "UDP"
    var id: Self { self }
}

enum RelayProvider: String, CaseIterable, Identifiable {
    case notSet = "N/A"
    case itak = "iTAK"
    case takAwareRelay = "TAK Aware"
    case companion = "WearTAK Companion"

    var id: Self { self }
}

enum TeamColor: String, CaseIterable, Identifiable {
    case white = "White"
    case yellow = "Yellow"
    case orange = "Orange"
    case magenta = "Magenta"
    case red = "Red"
    case maroon = "Maroon"
    case purple = "Purple"
    case darkBlue = "Dark Blue"
    case blue = "Blue"
    case cyan = "Cyan"
    case teal = "Teal"
    case green = "Green"
    case darkGreen = "Dark Green"
    case brown = "Brown"

    var id: Self { self }

    /// Matches CoT `__group name` case/spacing-insensitively ("Dark Green", "dark_green", "DarkGreen").
    init?(cotName: String?) {
        func key(_ value: String) -> String { value.lowercased().filter { $0.isLetter } }
        guard let name = cotName.map(key), !name.isEmpty,
              let match = Self.allCases.first(where: { key($0.rawValue) == name }) else { return nil }
        self = match
    }

    /// Light team colors need dark text/outline on map dots.
    var prefersDarkMarkerText: Bool {
        switch self {
        case .white, .yellow, .orange, .cyan, .green: return true
        default: return false
        }
    }
}

enum UserRoleGroup: String, CaseIterable, Identifiable {
    case military = "MIL"
    case lawEnforcement = "LEO"

    var id: Self { self }

    var roles: [String] {
        switch self {
        case .military:
            return ["Forward Observer", "HQ", "K9", "Medic", "RTO", "Sniper", "Team Lead", "Team Member"]
        case .lawEnforcement:
            return ["Armed Surveillance", "Assistant Team Leader", "Aviation", "Bomb Tech", "Command Post", "Critical Response", "Hazards", "Negotiator", "Surveillance", "Tactical Communicator", "TOC"]
        }
    }
}

enum ReportingStrategy: String, CaseIterable, Identifiable {
    case dynamic = "Dynamic Reporting"
    case constant = "Constant Reporting"

    var id: Self { self }
}

enum WiFiBatteryPolicy: String, CaseIterable, Identifiable {
    case all = "All WiFi Connections"
    case none = "No WiFi Connections"
    case some = "Some WiFi Connections"

    var id: Self { self }
}

/// Persisted preferences mirroring Garmin's Device/Network/Alerting/Tool Preferences menus.
@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let dashboardMetric = "WearTAK.dashboardMetric"
        static let mapButtonsVisible = "WearTAK.mapButtonsVisible"
        static let hiddenMapTeams = "WearTAK.hiddenMapTeams"
        static let hiddenMapRoles = "WearTAK.hiddenMapRoles"
        static let watchLabel = "WearTAK.watchLabel"
        static let callSign = "WearTAK.callSign"
        static let teamColor = "WearTAK.teamColor"
        static let roleGroup = "WearTAK.roleGroup"
        static let role = "WearTAK.role"
        static let reportingStrategy = "WearTAK.reportingStrategy"
        static let wifiBatteryPolicy = "WearTAK.wifiBatteryPolicy"
        static let stationaryReportingInterval = "WearTAK.stationaryReportingInterval"
        static let onFootReportingInterval = "WearTAK.onFootReportingInterval"
        static let vehicleReportingInterval = "WearTAK.vehicleReportingInterval"
        static let alertingReportingInterval = "WearTAK.alertingReportingInterval"
        static let constantReportingInterval = "WearTAK.constantReportingInterval"
        static let chatEnabled = "WearTAK.chatEnabled"
        static let relayProvider = "WearTAK.relayProvider"
        static let sitxApiHost = "WearTAK.sitxApiHost"
        static let sitxEnabled = "WearTAK.sitxEnabled"
        static let multicastEnabled = "WearTAK.multicastEnabled"
        static let multicastAddress = "WearTAK.multicastAddress"
        static let multicastPort = "WearTAK.multicastPort"
        static let multicastOutputProtocol = "WearTAK.multicastOutputProtocol"
        static let highRestingHeartRate = "WearTAK.highRestingHeartRate"
        static let lowRestingHeartRate = "WearTAK.lowRestingHeartRate"
        static let highRestingWarningMinutes = "WearTAK.highRestingWarningMinutes"
        static let highRestingAlertMinutes = "WearTAK.highRestingAlertMinutes"
        static let lowRestingWarningMinutes = "WearTAK.lowRestingWarningMinutes"
        static let lowRestingAlertMinutes = "WearTAK.lowRestingAlertMinutes"
        static let exertionWarningThreshold = "WearTAK.exertionWarningThreshold"
        static let exertionWarningLengthSeconds = "WearTAK.exertionWarningLengthSeconds"
        static let exertionAlertThreshold = "WearTAK.exertionAlertThreshold"
        static let exertionAlertLengthSeconds = "WearTAK.exertionAlertLengthSeconds"
        static let lowPressureThreshold = "WearTAK.lowPressureThreshold"
        static let highPressureThreshold = "WearTAK.highPressureThreshold"
        static let lowPressureAlertsEnabled = "WearTAK.lowPressureAlertsEnabled"
        static let highPressureAlertsEnabled = "WearTAK.highPressureAlertsEnabled"
        static let immersionAlertsEnabled = "WearTAK.immersionAlertsEnabled"
        static let batteryAlertsEnabled = "WearTAK.batteryAlertsEnabled"
        static let physiologicalAlertsEnabled = "WearTAK.physiologicalAlertsEnabled"
        static let physiologicalMonitoringEnabled = "WearTAK.physiologicalMonitoringEnabled"
        static let bloodhoundProximityRadius = "WearTAK.bloodhoundProximityRadius"
        static let bloodhoundProximityVibrationEnabled = "WearTAK.bloodhoundProximityVibrationEnabled"
        static let bloodhoundProximityIntensity = "WearTAK.bloodhoundProximityIntensity"
        static let birthYear = "WearTAK.birthYear"
        static let heightInches = "WearTAK.heightInches"
        static let weightPounds = "WearTAK.weightPounds"
        static let sex = "WearTAK.sex"
        static let bloodType = "WearTAK.bloodType"
        static let allergies = "WearTAK.allergies"
        static let userType = "WearTAK.userType"
        static let uniformWaistSize = "WearTAK.uniformWaistSize"
        static let strideLength = "WearTAK.strideLength"
        static let uniformPantsLength = "WearTAK.uniformPantsLength"
        static let loadoutWeight = "WearTAK.loadoutWeight"
    }

    static let sexOptions = ["Not Set", "Female", "Male"]
    static let bloodTypeOptions = ["Unknown", "A+", "A-", "B+", "B-", "AB+", "AB-", "O+", "O-"]
    static let allergyOptions = ["N/A", "Antibiotics", "Anti-Inflammatory (Ibuprofen)", "Antiseizure", "Aspirin", "Insulin", "Muscle Relaxers", "Sulfa Drugs"]
    static let userTypeOptions = ["N/A", "Child", "Coalition Civilian", "Coalition Military", "Non-Coalition Civilian", "Non-Coalition Military", "Opposing Force Detainee"]
    static let bloodhoundProximityIntensityOptions = ["Single Burst", "Triple Burst", "Until In Position"]

    private let defaults: UserDefaults

    @Published var dashboardMetric: DashboardMetric {
        didSet { defaults.set(dashboardMetric.rawValue, forKey: Keys.dashboardMetric) }
    }

    @Published var mapButtonsVisible: Bool {
        didSet { defaults.set(mapButtonsVisible, forKey: Keys.mapButtonsVisible) }
    }

    @Published var hiddenMapTeams: Set<String> {
        didSet { defaults.set(hiddenMapTeams.sorted(), forKey: Keys.hiddenMapTeams) }
    }

    @Published var hiddenMapRoles: Set<String> {
        didSet { defaults.set(hiddenMapRoles.sorted(), forKey: Keys.hiddenMapRoles) }
    }

    func isMapUserVisible(team: String?, role: String?) -> Bool {
        let teamKey = team?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let roleKey = role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return !hiddenMapTeams.contains(teamKey) && !hiddenMapRoles.contains(roleKey)
    }

    @Published var watchLabel: String {
        didSet { defaults.set(watchLabel, forKey: Keys.watchLabel) }
    }

    @Published var callSign: String {
        didSet { defaults.set(callSign, forKey: Keys.callSign) }
    }

    @Published var teamColor: TeamColor {
        didSet { defaults.set(teamColor.rawValue, forKey: Keys.teamColor) }
    }

    @Published var roleGroup: UserRoleGroup? {
        didSet { defaults.set(roleGroup?.rawValue, forKey: Keys.roleGroup) }
    }

    @Published var role: String {
        didSet { defaults.set(role, forKey: Keys.role) }
    }

    @Published var reportingStrategy: ReportingStrategy {
        didSet { defaults.set(reportingStrategy.rawValue, forKey: Keys.reportingStrategy) }
    }

    @Published var wifiBatteryPolicy: WiFiBatteryPolicy {
        didSet { defaults.set(wifiBatteryPolicy.rawValue, forKey: Keys.wifiBatteryPolicy) }
    }

    func reportingInterval(base: TimeInterval, isOnWiFi: Bool) -> TimeInterval {
        let boundedInterval = min(max(base, 1), 86_400)
        return boundedInterval * (wifiBatteryPolicy == .all && isOnWiFi ? 6 : 1)
    }

    @Published var stationaryReportingInterval: Int {
        didSet { setReportingInterval(stationaryReportingInterval, key: Keys.stationaryReportingInterval) }
    }

    @Published var onFootReportingInterval: Int {
        didSet { setReportingInterval(onFootReportingInterval, key: Keys.onFootReportingInterval) }
    }

    @Published var vehicleReportingInterval: Int {
        didSet { setReportingInterval(vehicleReportingInterval, key: Keys.vehicleReportingInterval) }
    }

    @Published var alertingReportingInterval: Int {
        didSet { setReportingInterval(alertingReportingInterval, key: Keys.alertingReportingInterval) }
    }

    @Published var constantReportingInterval: Int {
        didSet { setReportingInterval(constantReportingInterval, key: Keys.constantReportingInterval) }
    }

    @Published var chatEnabled: Bool {
        didSet { defaults.set(chatEnabled, forKey: Keys.chatEnabled) }
    }

    @Published var relayProvider: RelayProvider {
        didSet { defaults.set(relayProvider.rawValue, forKey: Keys.relayProvider) }
    }

    @Published var sitxApiHost: String {
        didSet { defaults.set(sitxApiHost, forKey: Keys.sitxApiHost) }
    }

    @Published var sitxEnabled: Bool {
        didSet { defaults.set(sitxEnabled, forKey: Keys.sitxEnabled) }
    }

    @Published var multicastEnabled: Bool {
        didSet { defaults.set(multicastEnabled, forKey: Keys.multicastEnabled) }
    }

    @Published var multicastAddress: String {
        didSet { defaults.set(multicastAddress, forKey: Keys.multicastAddress) }
    }

    @Published var multicastPort: Int {
        didSet {
            let clamped = min(max(multicastPort, 1), 65535)
            guard clamped == multicastPort else { multicastPort = clamped; return }
            defaults.set(multicastPort, forKey: Keys.multicastPort)
        }
    }

    @Published var multicastOutputProtocol: MulticastOutputProtocol {
        didSet { defaults.set(multicastOutputProtocol.rawValue, forKey: Keys.multicastOutputProtocol) }
    }

    static func isMulticastAddress(_ address: String) -> Bool {
        guard let firstByte = IPv4Address(address)?.rawValue.first else { return false }
        return (224...239).contains(firstByte)
    }

    @Published var highRestingHeartRate: Int {
        didSet {
            let clamped = min(max(highRestingHeartRate, 80), 200)
            guard clamped == highRestingHeartRate else { highRestingHeartRate = clamped; return }
            guard highRestingHeartRate > lowRestingHeartRate else { highRestingHeartRate = lowRestingHeartRate + 20; return }
            defaults.set(highRestingHeartRate, forKey: Keys.highRestingHeartRate)
        }
    }

    @Published var lowRestingHeartRate: Int {
        didSet {
            let clamped = min(max(lowRestingHeartRate, 25), 100)
            guard clamped == lowRestingHeartRate else { lowRestingHeartRate = clamped; return }
            guard highRestingHeartRate > lowRestingHeartRate else { highRestingHeartRate = min(lowRestingHeartRate + 20, 200); return }
            defaults.set(lowRestingHeartRate, forKey: Keys.lowRestingHeartRate)
        }
    }

    @Published var highRestingWarningMinutes: Int {
        didSet {
            let clamped = min(max(highRestingWarningMinutes, 1), 60)
            guard clamped == highRestingWarningMinutes else { highRestingWarningMinutes = clamped; return }
            defaults.set(highRestingWarningMinutes, forKey: Keys.highRestingWarningMinutes)
        }
    }

    @Published var highRestingAlertMinutes: Int {
        didSet {
            let clamped = min(max(highRestingAlertMinutes, 1), 60)
            guard clamped == highRestingAlertMinutes else { highRestingAlertMinutes = clamped; return }
            defaults.set(highRestingAlertMinutes, forKey: Keys.highRestingAlertMinutes)
        }
    }

    @Published var lowRestingWarningMinutes: Int {
        didSet {
            let clamped = min(max(lowRestingWarningMinutes, 1), 60)
            guard clamped == lowRestingWarningMinutes else { lowRestingWarningMinutes = clamped; return }
            defaults.set(lowRestingWarningMinutes, forKey: Keys.lowRestingWarningMinutes)
        }
    }

    @Published var lowRestingAlertMinutes: Int {
        didSet {
            let clamped = min(max(lowRestingAlertMinutes, 1), 60)
            guard clamped == lowRestingAlertMinutes else { lowRestingAlertMinutes = clamped; return }
            defaults.set(lowRestingAlertMinutes, forKey: Keys.lowRestingAlertMinutes)
        }
    }

    @Published var exertionWarningThreshold: Int {
        didSet {
            let clamped = min(max(exertionWarningThreshold, 50), 100) / 5 * 5
            guard clamped == exertionWarningThreshold else { exertionWarningThreshold = clamped; return }
            if exertionAlertThreshold < exertionWarningThreshold {
                exertionAlertThreshold = exertionWarningThreshold
            }
            defaults.set(exertionWarningThreshold, forKey: Keys.exertionWarningThreshold)
        }
    }

    @Published var exertionWarningLengthSeconds: Int {
        didSet {
            let clamped = min(max(exertionWarningLengthSeconds, 30), 600) / 30 * 30
            guard clamped == exertionWarningLengthSeconds else { exertionWarningLengthSeconds = clamped; return }
            defaults.set(exertionWarningLengthSeconds, forKey: Keys.exertionWarningLengthSeconds)
        }
    }

    @Published var exertionAlertThreshold: Int {
        didSet {
            let clamped = min(max(exertionAlertThreshold, 50), 100) / 5 * 5
            guard clamped == exertionAlertThreshold else { exertionAlertThreshold = clamped; return }
            if exertionAlertThreshold < exertionWarningThreshold {
                exertionWarningThreshold = exertionAlertThreshold
            }
            defaults.set(exertionAlertThreshold, forKey: Keys.exertionAlertThreshold)
        }
    }

    @Published var exertionAlertLengthSeconds: Int {
        didSet {
            let clamped = min(max(exertionAlertLengthSeconds, 30), 600) / 30 * 30
            guard clamped == exertionAlertLengthSeconds else { exertionAlertLengthSeconds = clamped; return }
            defaults.set(exertionAlertLengthSeconds, forKey: Keys.exertionAlertLengthSeconds)
        }
    }

    @Published var lowPressureThreshold: Int {
        didSet {
            let clamped = min(max(lowPressureThreshold, 800), 1100)
            guard clamped == lowPressureThreshold else { lowPressureThreshold = clamped; return }
            defaults.set(lowPressureThreshold, forKey: Keys.lowPressureThreshold)
        }
    }

    @Published var highPressureThreshold: Int {
        didSet {
            let clamped = min(max(highPressureThreshold, 1000), 1100)
            guard clamped == highPressureThreshold else { highPressureThreshold = clamped; return }
            guard highPressureThreshold >= lowPressureThreshold else {
                highPressureThreshold = lowPressureThreshold + 25
                return
            }
            defaults.set(highPressureThreshold, forKey: Keys.highPressureThreshold)
        }
    }

    @Published var lowPressureAlertsEnabled: Bool {
        didSet { defaults.set(lowPressureAlertsEnabled, forKey: Keys.lowPressureAlertsEnabled) }
    }

    @Published var highPressureAlertsEnabled: Bool {
        didSet { defaults.set(highPressureAlertsEnabled, forKey: Keys.highPressureAlertsEnabled) }
    }

    @Published var immersionAlertsEnabled: Bool {
        didSet { defaults.set(immersionAlertsEnabled, forKey: Keys.immersionAlertsEnabled) }
    }

    var environmentalAlertsEnabled: Bool {
        lowPressureAlertsEnabled || highPressureAlertsEnabled || immersionAlertsEnabled
    }

    @Published var batteryAlertsEnabled: Bool {
        didSet { defaults.set(batteryAlertsEnabled, forKey: Keys.batteryAlertsEnabled) }
    }

    @Published var physiologicalAlertsEnabled: Bool {
        didSet { defaults.set(physiologicalAlertsEnabled, forKey: Keys.physiologicalAlertsEnabled) }
    }

    @Published var physiologicalMonitoringEnabled: Bool {
        didSet { defaults.set(physiologicalMonitoringEnabled, forKey: Keys.physiologicalMonitoringEnabled) }
    }

    @Published var bloodhoundProximityRadius: Int {
        didSet {
            let clamped = min(max(bloodhoundProximityRadius, 10), 200)
            guard clamped == bloodhoundProximityRadius else { bloodhoundProximityRadius = clamped; return }
            defaults.set(bloodhoundProximityRadius, forKey: Keys.bloodhoundProximityRadius)
        }
    }

    @Published var bloodhoundProximityVibrationEnabled: Bool {
        didSet { defaults.set(bloodhoundProximityVibrationEnabled, forKey: Keys.bloodhoundProximityVibrationEnabled) }
    }

    @Published var bloodhoundProximityIntensity: String {
        didSet { defaults.set(bloodhoundProximityIntensity, forKey: Keys.bloodhoundProximityIntensity) }
    }

    @Published var birthYear: Int {
        didSet {
            let clamped = min(max(birthYear, 1920), Calendar.current.component(.year, from: Date()))
            guard clamped == birthYear else { birthYear = clamped; return }
            defaults.set(birthYear, forKey: Keys.birthYear)
        }
    }

    @Published var heightInches: Int {
        didSet {
            let clamped = min(max(heightInches, 48), 84)
            guard clamped == heightInches else { heightInches = clamped; return }
            defaults.set(heightInches, forKey: Keys.heightInches)
        }
    }

    @Published var weightPounds: Int {
        didSet {
            let clamped = min(max(weightPounds, 80), 320)
            guard clamped == weightPounds else { weightPounds = clamped; return }
            defaults.set(weightPounds, forKey: Keys.weightPounds)
        }
    }

    @Published var sex: String {
        didSet { defaults.set(sex, forKey: Keys.sex) }
    }

    @Published var bloodType: String {
        didSet { defaults.set(bloodType, forKey: Keys.bloodType) }
    }

    @Published var allergies: [String] {
        didSet { defaults.set(allergies.isEmpty ? ["N/A"] : allergies, forKey: Keys.allergies) }
    }

    @Published var userType: String {
        didSet { defaults.set(userType, forKey: Keys.userType) }
    }

    @Published var uniformWaistSize: Int {
        didSet {
            let clamped = min(max(uniformWaistSize, 24), 60)
            guard clamped == uniformWaistSize else { uniformWaistSize = clamped; return }
            defaults.set(uniformWaistSize, forKey: Keys.uniformWaistSize)
        }
    }

    @Published var strideLength: Int {
        didSet {
            let clamped = min(max(strideLength, 20), 45)
            guard clamped == strideLength else { strideLength = clamped; return }
            defaults.set(strideLength, forKey: Keys.strideLength)
        }
    }

    @Published var uniformPantsLength: Int {
        didSet {
            let clamped = min(max(uniformPantsLength, 24), 60)
            guard clamped == uniformPantsLength else { uniformPantsLength = clamped; return }
            defaults.set(uniformPantsLength, forKey: Keys.uniformPantsLength)
        }
    }

    @Published var loadoutWeight: Int {
        didSet {
            let clamped = min(max(loadoutWeight, 10), 150)
            guard clamped == loadoutWeight else { loadoutWeight = clamped; return }
            defaults.set(loadoutWeight, forKey: Keys.loadoutWeight)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dashboardMetric = DashboardMetric(rawValue: defaults.string(forKey: Keys.dashboardMetric) ?? "") ?? .exertion
        mapButtonsVisible = defaults.object(forKey: Keys.mapButtonsVisible) as? Bool ?? true
        hiddenMapTeams = Set(defaults.stringArray(forKey: Keys.hiddenMapTeams) ?? [])
        hiddenMapRoles = Set(defaults.stringArray(forKey: Keys.hiddenMapRoles) ?? [])
        reportingStrategy = ReportingStrategy(rawValue: defaults.string(forKey: Keys.reportingStrategy) ?? ReportingStrategy.dynamic.rawValue) ?? .dynamic
        wifiBatteryPolicy = WiFiBatteryPolicy(rawValue: defaults.string(forKey: Keys.wifiBatteryPolicy) ?? WiFiBatteryPolicy.none.rawValue) ?? .none
        stationaryReportingInterval = defaults.object(forKey: Keys.stationaryReportingInterval) as? Int ?? 3600
        onFootReportingInterval = defaults.object(forKey: Keys.onFootReportingInterval) as? Int ?? 60
        vehicleReportingInterval = defaults.object(forKey: Keys.vehicleReportingInterval) as? Int ?? 60
        alertingReportingInterval = defaults.object(forKey: Keys.alertingReportingInterval) as? Int ?? 10
        constantReportingInterval = defaults.object(forKey: Keys.constantReportingInterval) as? Int ?? 60
        watchLabel = defaults.string(forKey: Keys.watchLabel) ?? "WearTAK Apple Watch"
        callSign = defaults.string(forKey: Keys.callSign) ?? ""
        teamColor = TeamColor(rawValue: defaults.string(forKey: Keys.teamColor) ?? "White") ?? .white
        roleGroup = defaults.string(forKey: Keys.roleGroup).flatMap(UserRoleGroup.init(rawValue:))
        role = defaults.string(forKey: Keys.role) ?? ""
        chatEnabled = defaults.object(forKey: Keys.chatEnabled) as? Bool ?? true
        let storedRelayProvider = defaults.string(forKey: Keys.relayProvider)
        if storedRelayProvider == "TAK Aware Relay" {
            relayProvider = .takAwareRelay
        } else {
            relayProvider = RelayProvider(rawValue: storedRelayProvider ?? "N/A") ?? .notSet
        }
        let storedSitxHost = defaults.string(forKey: Keys.sitxApiHost) ?? ""
        sitxApiHost = storedSitxHost
        sitxEnabled = defaults.object(forKey: Keys.sitxEnabled) as? Bool ?? !storedSitxHost.isEmpty
        multicastEnabled = defaults.object(forKey: Keys.multicastEnabled) as? Bool ?? true
        multicastAddress = defaults.string(forKey: Keys.multicastAddress) ?? "239.2.3.1"
        multicastPort = min(max(defaults.object(forKey: Keys.multicastPort) as? Int ?? 6969, 1), 65535)
        multicastOutputProtocol = MulticastOutputProtocol(rawValue: defaults.string(forKey: Keys.multicastOutputProtocol) ?? "UDP") ?? .udp
        highRestingHeartRate = defaults.object(forKey: Keys.highRestingHeartRate) as? Int ?? 120
        lowRestingHeartRate = defaults.object(forKey: Keys.lowRestingHeartRate) as? Int ?? 40
        highRestingWarningMinutes = defaults.object(forKey: Keys.highRestingWarningMinutes) as? Int ?? 5
        highRestingAlertMinutes = defaults.object(forKey: Keys.highRestingAlertMinutes) as? Int ?? 10
        lowRestingWarningMinutes = defaults.object(forKey: Keys.lowRestingWarningMinutes) as? Int ?? 5
        lowRestingAlertMinutes = defaults.object(forKey: Keys.lowRestingAlertMinutes) as? Int ?? 10
        exertionWarningThreshold = defaults.object(forKey: Keys.exertionWarningThreshold) as? Int ?? 80
        exertionWarningLengthSeconds = defaults.object(forKey: Keys.exertionWarningLengthSeconds) as? Int ?? 120
        exertionAlertThreshold = defaults.object(forKey: Keys.exertionAlertThreshold) as? Int ?? 90
        exertionAlertLengthSeconds = defaults.object(forKey: Keys.exertionAlertLengthSeconds) as? Int ?? 120
        lowPressureThreshold = defaults.object(forKey: Keys.lowPressureThreshold) as? Int ?? 950
        let storedHighPressureThreshold = defaults.object(forKey: Keys.highPressureThreshold) as? Int
        if let storedHighPressureThreshold, storedHighPressureThreshold != 2000 {
            highPressureThreshold = min(max(storedHighPressureThreshold, 1000), 1100)
        } else {
            highPressureThreshold = 1050
        }
        lowPressureAlertsEnabled = defaults.object(forKey: Keys.lowPressureAlertsEnabled) as? Bool ?? false
        highPressureAlertsEnabled = defaults.object(forKey: Keys.highPressureAlertsEnabled) as? Bool ?? false
        immersionAlertsEnabled = defaults.object(forKey: Keys.immersionAlertsEnabled) as? Bool ?? false
        batteryAlertsEnabled = defaults.object(forKey: Keys.batteryAlertsEnabled) as? Bool ?? false
        physiologicalAlertsEnabled = defaults.object(forKey: Keys.physiologicalAlertsEnabled) as? Bool ?? false
        physiologicalMonitoringEnabled = defaults.object(forKey: Keys.physiologicalMonitoringEnabled) as? Bool ?? true
        bloodhoundProximityRadius = defaults.object(forKey: Keys.bloodhoundProximityRadius) as? Int ?? 50
        bloodhoundProximityVibrationEnabled = defaults.object(forKey: Keys.bloodhoundProximityVibrationEnabled) as? Bool ?? true
        bloodhoundProximityIntensity = defaults.string(forKey: Keys.bloodhoundProximityIntensity) ?? "Single Burst"
        birthYear = defaults.object(forKey: Keys.birthYear) as? Int ?? 1990
        heightInches = defaults.object(forKey: Keys.heightInches) as? Int ?? 68
        weightPounds = defaults.object(forKey: Keys.weightPounds) as? Int ?? 155
        sex = defaults.string(forKey: Keys.sex) ?? "Not Set"
        bloodType = defaults.string(forKey: Keys.bloodType) ?? "Unknown"
        allergies = defaults.stringArray(forKey: Keys.allergies) ?? ["N/A"]
        userType = defaults.string(forKey: Keys.userType) ?? "N/A"
        uniformWaistSize = defaults.object(forKey: Keys.uniformWaistSize) as? Int ?? 32
        strideLength = defaults.object(forKey: Keys.strideLength) as? Int ?? 30
        uniformPantsLength = defaults.object(forKey: Keys.uniformPantsLength) as? Int ?? 32
        loadoutWeight = defaults.object(forKey: Keys.loadoutWeight) as? Int ?? 72
    }

    private func setReportingInterval(_ value: Int, key: String) {
        defaults.set(min(max(value, 1), 86_400), forKey: key)
    }

    func toggleAllergy(_ allergy: String) {
        if allergy == "N/A" {
            allergies = ["N/A"]
        } else if allergies.contains(allergy) {
            allergies.removeAll { $0 == allergy }
            if allergies.isEmpty { allergies = ["N/A"] }
        } else {
            allergies.removeAll { $0 == "N/A" }
            allergies.append(allergy)
        }
    }
}
