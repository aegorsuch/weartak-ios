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
    private var freshnessTimer: Timer?
    private var monitoringStartedAt: Date?
    private var lastReadingAt: Date?

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
        monitoringStartedAt = Date()
        lastReadingAt = nil
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
            guard let self else { return }
            if let error {
                Task { @MainActor in self.handleBarometerError(error) }
                return
            }
            guard let data else { return }
            Task { @MainActor in
                self.process(
                    pressureKilopascals: data.pressure.doubleValue,
                    relativeAltitudeMeters: data.relativeAltitude.doubleValue
                )
            }
        }
        freshnessTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.expireStaleReadings() }
        }
    }

    func stopMonitoring() {
        altimeter.stopRelativeAltitudeUpdates()
        freshnessTimer?.invalidate()
        freshnessTimer = nil
        isMonitoring = false
        monitoringStartedAt = nil
        lastReadingAt = nil
        evaluator.reset()
        activePressureCategory = nil
        immersionActive = false
        status = "Monitoring stopped"
    }

    private func process(pressureKilopascals: Double, relativeAltitudeMeters: Double) {
        let hpa = pressureKilopascals * 10
        guard hpa.isFinite, hpa > 0, relativeAltitudeMeters.isFinite else {
            clearAlerts()
            status = "Invalid barometer reading"
            return
        }
        lastReadingAt = Date()
        status = "Monitoring pressure"
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

    private func expireStaleReadings() {
        let now = Date()
        if evaluator.expire(at: now) {
            activePressureCategory = nil
            immersionActive = false
            status = "Pressure readings stale"
            lastReadingAt = nil
        } else if lastReadingAt == nil, let monitoringStartedAt,
                  now.timeIntervalSince(monitoringStartedAt) > 30 {
            status = "No pressure readings"
        }
    }

    private func handleBarometerError(_ error: Error) {
        altimeter.stopRelativeAltitudeUpdates()
        freshnessTimer?.invalidate()
        freshnessTimer = nil
        isMonitoring = false
        monitoringStartedAt = nil
        lastReadingAt = nil
        clearAlerts()
        let code = (error as NSError).code
        status = "Barometer error (\(code))"
    }

    private func clearAlerts() {
        evaluator.reset()
        activePressureCategory = nil
        immersionActive = false
    }
}
