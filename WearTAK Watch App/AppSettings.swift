import Combine
import Foundation

/// Persisted preferences mirroring Garmin's Device/Network/Alerting/Tool Preferences menus.
@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let watchLabel = "WearTAK.watchLabel"
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
    }

    private let defaults: UserDefaults

    @Published var watchLabel: String {
        didSet { defaults.set(watchLabel, forKey: Keys.watchLabel) }
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        watchLabel = defaults.string(forKey: Keys.watchLabel) ?? "WearTAK Apple Watch"
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
    }
}
