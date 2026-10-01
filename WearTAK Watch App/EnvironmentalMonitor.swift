import Combine
import CoreMotion
import Foundation

@MainActor
final class EnvironmentalMonitor: ObservableObject {
    @Published private(set) var relativeAltitudeMeters: Double?
    @Published private(set) var pressureHpa: Double?
    @Published private(set) var status = "Barometer not started"
    @Published private(set) var isMonitoring = false
    @Published private(set) var activePressureCategory: EnvironmentalAlertCategory?
    @Published private(set) var immersionActive = false

    private let altimeter = CMAltimeter()
    private let settings: AppSettings
    private var evaluator = EnvironmentalAlertEvaluator()

    init(settings: AppSettings) {
        self.settings = settings
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            status = "Barometer unavailable"
            return
        }
        isMonitoring = true
        status = "Monitoring pressure"
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self, let data, error == nil else { return }
            Task { @MainActor in
                self.process(
                    pressureKilopascals: data.pressure.doubleValue,
                    relativeAltitudeMeters: data.relativeAltitude.doubleValue
                )
            }
        }
    }

    func stopMonitoring() {
        altimeter.stopRelativeAltitudeUpdates()
        isMonitoring = false
        evaluator.reset()
        activePressureCategory = nil
        immersionActive = false
        status = "Monitoring stopped"
    }

    private func process(pressureKilopascals: Double, relativeAltitudeMeters: Double) {
        let hpa = pressureKilopascals * 10
        pressureHpa = hpa
        self.relativeAltitudeMeters = relativeAltitudeMeters
        evaluator.evaluate(
            pressureHpa: hpa, at: Date(),
            settings: EnvironmentalAlertSettings(
                lowThresholdHpa: Double(settings.lowPressureThreshold),
                highThresholdHpa: Double(settings.highPressureThreshold),
                lowEnabled: settings.lowPressureAlertsEnabled,
                highEnabled: settings.highPressureAlertsEnabled,
                immersionEnabled: settings.immersionAlertsEnabled
            )
        )
        activePressureCategory = evaluator.activePressureCategory
        immersionActive = evaluator.immersionActive
    }
}
