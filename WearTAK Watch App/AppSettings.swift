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
        static let relayProvider = "WearTAK.relayProvider"
        static let sitxApiHost = "WearTAK.sitxApiHost"
        static let highRestingHeartRate = "WearTAK.highRestingHeartRate"
        static let lowRestingHeartRate = "WearTAK.lowRestingHeartRate"
        static let exertionWarningThreshold = "WearTAK.exertionWarningThreshold"
        static let exertionAlertThreshold = "WearTAK.exertionAlertThreshold"
        static let lowPressureThreshold = "WearTAK.lowPressureThreshold"
        static let highPressureThreshold = "WearTAK.highPressureThreshold"
        static let lowPressureAlertsEnabled = "WearTAK.lowPressureAlertsEnabled"
        static let highPressureAlertsEnabled = "WearTAK.highPressureAlertsEnabled"
        static let immersionAlertsEnabled = "WearTAK.immersionAlertsEnabled"
        static let physiologicalAlertsEnabled = "WearTAK.physiologicalAlertsEnabled"
        static let bloodhoundProximityRadius = "WearTAK.bloodhoundProximityRadius"
        static let bloodhoundProximityVibrationEnabled = "WearTAK.bloodhoundProximityVibrationEnabled"
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

    private let defaults: UserDefaults

    @Published var watchLabel: String {
        didSet { defaults.set(watchLabel, forKey: Keys.watchLabel) }
    }

    @Published var relayProvider: RelayProvider {
        didSet { defaults.set(relayProvider.rawValue, forKey: Keys.relayProvider) }
    }

    @Published var sitxApiHost: String {
        didSet { defaults.set(sitxApiHost, forKey: Keys.sitxApiHost) }
    }

    @Published var highRestingHeartRate: Int {
        didSet {
            let clamped = min(max(highRestingHeartRate, 80), 220)
            guard clamped == highRestingHeartRate else { highRestingHeartRate = clamped; return }
            guard highRestingHeartRate > lowRestingHeartRate else { highRestingHeartRate = lowRestingHeartRate + 20; return }
            defaults.set(highRestingHeartRate, forKey: Keys.highRestingHeartRate)
        }
    }

    @Published var lowRestingHeartRate: Int {
        didSet {
            let clamped = min(max(lowRestingHeartRate, 25), 110)
            guard clamped == lowRestingHeartRate else { lowRestingHeartRate = clamped; return }
            defaults.set(lowRestingHeartRate, forKey: Keys.lowRestingHeartRate)
        }
    }

    @Published var exertionWarningThreshold: Int {
        didSet {
            let clamped = min(max(exertionWarningThreshold, 50), 100)
            guard clamped == exertionWarningThreshold else { exertionWarningThreshold = clamped; return }
            defaults.set(exertionWarningThreshold, forKey: Keys.exertionWarningThreshold)
        }
    }

    @Published var exertionAlertThreshold: Int {
        didSet {
            let clamped = min(max(exertionAlertThreshold, 50), 100)
            guard clamped == exertionAlertThreshold else { exertionAlertThreshold = clamped; return }
            guard exertionAlertThreshold >= exertionWarningThreshold else {
                exertionAlertThreshold = exertionWarningThreshold + 5
                return
            }
            defaults.set(exertionAlertThreshold, forKey: Keys.exertionAlertThreshold)
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
            let clamped = min(max(highPressureThreshold, 1000), 3000)
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
        let storedRelayProvider = defaults.string(forKey: Keys.relayProvider)
        if storedRelayProvider == "TAK Aware Relay" {
            relayProvider = .takAwareRelay
        } else {
            relayProvider = RelayProvider(rawValue: storedRelayProvider ?? "N/A") ?? .notSet
        }
        sitxApiHost = defaults.string(forKey: Keys.sitxApiHost) ?? ""
        highRestingHeartRate = defaults.object(forKey: Keys.highRestingHeartRate) as? Int ?? 120
        lowRestingHeartRate = defaults.object(forKey: Keys.lowRestingHeartRate) as? Int ?? 40
        exertionWarningThreshold = defaults.object(forKey: Keys.exertionWarningThreshold) as? Int ?? 80
        exertionAlertThreshold = defaults.object(forKey: Keys.exertionAlertThreshold) as? Int ?? 90
        lowPressureThreshold = defaults.object(forKey: Keys.lowPressureThreshold) as? Int ?? 950
        highPressureThreshold = defaults.object(forKey: Keys.highPressureThreshold) as? Int ?? 2000
        lowPressureAlertsEnabled = defaults.object(forKey: Keys.lowPressureAlertsEnabled) as? Bool ?? true
        highPressureAlertsEnabled = defaults.object(forKey: Keys.highPressureAlertsEnabled) as? Bool ?? true
        immersionAlertsEnabled = defaults.object(forKey: Keys.immersionAlertsEnabled) as? Bool ?? true
        physiologicalAlertsEnabled = defaults.object(forKey: Keys.physiologicalAlertsEnabled) as? Bool ?? true
        bloodhoundProximityRadius = defaults.object(forKey: Keys.bloodhoundProximityRadius) as? Int ?? 50
        bloodhoundProximityVibrationEnabled = defaults.object(forKey: Keys.bloodhoundProximityVibrationEnabled) as? Bool ?? true
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
