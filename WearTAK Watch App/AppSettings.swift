import Combine
import Foundation

enum RelayProvider: String, CaseIterable, Identifiable {
    case notSet = "N/A"
    case itak = "iTAK"
    case takAwareRelay = "TAK Aware"

    var id: Self { self }
}

/// Persisted preferences mirroring Garmin's Device/Network/Alerting/Tool Preferences menus.
@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let watchLabel = "WearTAK.watchLabel"
        static let callSign = "WearTAK.callSign"
        static let chatEnabled = "WearTAK.chatEnabled"
        static let relayProvider = "WearTAK.relayProvider"
        static let sitxApiHost = "WearTAK.sitxApiHost"
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

    @Published var watchLabel: String {
        didSet { defaults.set(watchLabel, forKey: Keys.watchLabel) }
    }

    @Published var callSign: String {
        didSet { defaults.set(callSign, forKey: Keys.callSign) }
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
        watchLabel = defaults.string(forKey: Keys.watchLabel) ?? "WearTAK Apple Watch"
        callSign = defaults.string(forKey: Keys.callSign) ?? ""
        chatEnabled = defaults.object(forKey: Keys.chatEnabled) as? Bool ?? true
        let storedRelayProvider = defaults.string(forKey: Keys.relayProvider)
        if storedRelayProvider == "TAK Aware Relay" {
            relayProvider = .takAwareRelay
        } else {
            relayProvider = RelayProvider(rawValue: storedRelayProvider ?? "N/A") ?? .notSet
        }
        sitxApiHost = defaults.string(forKey: Keys.sitxApiHost) ?? ""
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
