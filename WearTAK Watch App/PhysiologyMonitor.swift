import Combine
import CoreMotion
import Foundation
import HealthKit

@MainActor
final class PhysiologyMonitor: ObservableObject {
    @Published private(set) var heartRate: Int?
    @Published private(set) var readingDate: Date?
    @Published private(set) var status = "Health access not requested"
    @Published private(set) var isViewing = false
    @Published private(set) var automaticEnabled = false
    @Published private(set) var isStarting = false
    @Published private(set) var activeAutomaticAlert: AutomaticAlertCategory?
    @Published private(set) var warningCategory: AutomaticAlertCategory?

    var exertionPercent: Int? {
        guard let heartRate, let age, (18...100).contains(age) else { return nil }
        let predictedMaximum = 208 - 0.7 * Double(age)
        return Int((Double(heartRate) / predictedMaximum * 100).rounded())
    }

    private let healthStore = HKHealthStore()
    private let pedometer = CMPedometer()
    private let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)!
    private var observerQuery: HKObserverQuery?
    private var freshnessTimer: Timer?
    private var evaluator = AutomaticAlertEvaluator()
    private var lastProcessedSampleID: UUID?
    private var monitoringGeneration = 0
    private var age: Int?
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func refresh() async {
        guard settings.physiologicalMonitoringEnabled else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            status = "Health data unavailable"
            return
        }

        do {
            try await healthStore.requestAuthorization(toShare: [], read: [heartRateType])
            age = Calendar.current.component(.year, from: Date()) - settings.birthYear
            await loadLatestReading()
        } catch {
            clearReading(status: "Health access unavailable")
        }
    }

    func startMonitoring() async {
        guard settings.physiologicalMonitoringEnabled else { return }
        guard !automaticEnabled && !isStarting else { return }
        guard settings.physiologicalAlertsEnabled else {
            status = "Enable Physiological Alerts in Settings"
            return
        }
        isStarting = true
        defer { isStarting = false }
        let generation = monitoringGeneration
        guard CMPedometer.isStepCountingAvailable() else {
            status = "Motion data unavailable"
            return
        }
        await refresh()
        guard generation == monitoringGeneration, settings.physiologicalMonitoringEnabled else { return }
        guard HKHealthStore.isHealthDataAvailable(), status != "Health access unavailable" else { return }

        automaticEnabled = true
        status = heartRate == nil ? "Waiting for heart rate or access" : "Monitoring for new readings"
        startObservingSamples()
    }

    func startViewing() async {
        guard settings.physiologicalMonitoringEnabled else { return }
        guard !isViewing else { return }
        isViewing = true
        await refresh()
        guard isViewing, HKHealthStore.isHealthDataAvailable() else { return }
        startObservingSamples()
    }

    func stopViewing() {
        isViewing = false
        if !automaticEnabled {
            stopObservingSamples()
        }
    }

    func stopSensing() {
        stopViewing()
        stopMonitoring()
        clearReading(status: "Physiological monitoring off")
    }

    private func startObservingSamples() {
        guard observerQuery == nil else { return }
        let query = HKObserverQuery(sampleType: heartRateType, predicate: nil) { [weak self] _, completion, error in
            Task { @MainActor [weak self] in
                if error != nil {
                    self?.stopMonitoring()
                    self?.stopViewing()
                    self?.status = "Heart rate updates unavailable"
                } else {
                    await self?.loadLatestReading()
                }
                completion()
            }
        }
        observerQuery = query
        healthStore.execute(query)
        if freshnessTimer == nil {
            freshnessTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.expireReading() }
            }
        }
    }

    func stopMonitoring() {
        automaticEnabled = false
        evaluator.reset()
        activeAutomaticAlert = nil
        warningCategory = nil
        if !isViewing {
            stopObservingSamples()
        } else {
            status = "Live heart-rate updates"
        }
    }

    private func stopObservingSamples() {
        monitoringGeneration += 1
        if let observerQuery {
            healthStore.stop(observerQuery)
        }
        observerQuery = nil
        freshnessTimer?.invalidate()
        freshnessTimer = nil
        lastProcessedSampleID = nil
        evaluator.reset()
        activeAutomaticAlert = nil
        warningCategory = nil
        if !isViewing && !automaticEnabled {
            status = "Monitoring stopped"
        }
    }

    private func loadLatestReading() async {
        guard settings.physiologicalMonitoringEnabled else { return }
        let generation = monitoringGeneration
        do {
            let sample = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HKQuantitySample?, Error>) in
                let query = HKSampleQuery(
                    sampleType: heartRateType,
                    predicate: HKQuery.predicateForSamples(
                        withStart: Date().addingTimeInterval(-300), end: nil, options: .strictStartDate
                    ),
                    limit: 1,
                    sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
                ) { _, samples, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: samples?.first as? HKQuantitySample)
                    }
                }
                healthStore.execute(query)
            }

            guard settings.physiologicalMonitoringEnabled, generation == monitoringGeneration else { return }
            if let sample {
                let beatsPerMinute = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                heartRate = Int(beatsPerMinute.rounded())
                readingDate = sample.endDate
                status = automaticEnabled
                    ? (Date().timeIntervalSince(sample.endDate) <= 60 ? "Monitoring for new readings" : "Waiting for fresh heart rate")
                    : (isViewing ? "Live heart-rate updates" : "Latest reading")
                if automaticEnabled && sample.uuid != lastProcessedSampleID {
                    lastProcessedSampleID = sample.uuid
                    await evaluate(sample: sample, beatsPerMinute: beatsPerMinute)
                }
            } else {
                clearReading(status: "No recent reading or access denied")
            }
        } catch {
            clearReading(status: "Health access unavailable")
        }
    }

    private func evaluate(sample: HKQuantitySample, beatsPerMinute: Double) async {
        guard settings.physiologicalAlertsEnabled else {
            evaluator.reset()
            activeAutomaticAlert = nil
            warningCategory = nil
            return
        }
        guard (0...60).contains(Date().timeIntervalSince(sample.endDate)) else {
            evaluator.reset()
            activeAutomaticAlert = nil
            warningCategory = nil
            return
        }
        let movement = await withCheckedContinuation { (continuation: CheckedContinuation<MovementState, Never>) in
            pedometer.queryPedometerData(from: sample.endDate.addingTimeInterval(-60), to: sample.endDate) { data, error in
                if let data, error == nil {
                    continuation.resume(returning: data.numberOfSteps.intValue == 0 ? .stationary : .moving)
                } else {
                    continuation.resume(returning: .unknown)
                }
            }
        }
        guard automaticEnabled else { return }
        let thresholds = AutomaticAlertThresholds(
            highResting: Double(settings.highRestingHeartRate),
            lowResting: Double(settings.lowRestingHeartRate),
            exertionWarningFraction: Double(settings.exertionWarningThreshold) / 100,
            exertionAlertFraction: Double(settings.exertionAlertThreshold) / 100,
            highRestingWarningDuration: Double(settings.highRestingWarningMinutes * 60),
            highRestingAlertDuration: Double(settings.highRestingAlertMinutes * 60),
            lowRestingWarningDuration: Double(settings.lowRestingWarningMinutes * 60),
            lowRestingAlertDuration: Double(settings.lowRestingAlertMinutes * 60),
            exertionWarningDuration: Double(settings.exertionWarningLengthSeconds),
            exertionAlertDuration: Double(settings.exertionAlertLengthSeconds)
        )
        evaluator.evaluate(heartRate: beatsPerMinute, at: sample.endDate, movement: movement, age: age, thresholds: thresholds)
        activeAutomaticAlert = evaluator.activeCategory
        warningCategory = evaluator.warningCategory
    }

    private func expireReading() {
        evaluator.expire(at: Date())
        activeAutomaticAlert = evaluator.activeCategory
        warningCategory = evaluator.warningCategory
        if let readingDate, Date().timeIntervalSince(readingDate) > 60 {
            status = "Waiting for fresh heart rate"
        }
    }

    private func clearReading(status: String) {
        heartRate = nil
        readingDate = nil
        self.status = status
        evaluator.reset()
        activeAutomaticAlert = nil
        warningCategory = nil
    }
}