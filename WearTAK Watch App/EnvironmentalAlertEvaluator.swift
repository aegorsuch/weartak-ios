import Foundation

enum EnvironmentalAlertCategory: String {
    case lowPressure = "Low atmospheric pressure"
    case highPressure = "High atmospheric pressure"
    case immersion = "Immersion"
}

struct EnvironmentalAlertSettings {
    var lowThresholdHpa: Double
    var highThresholdHpa: Double
    var lowEnabled: Bool
    var highEnabled: Bool
    var immersionEnabled: Bool
}

/// Ports Garmin's rolling-average pressure alerts and sustained-rise immersion detector.
struct EnvironmentalAlertEvaluator {
    private(set) var activePressureCategory: EnvironmentalAlertCategory?
    private(set) var immersionActive = false

    private var samples: [Double] = []
    private var lastSampleAt: Date?
    private var lowSince: Date?
    private var highSince: Date?
    private var immersionBaseline: Double?
    private var immersionSampleCount = 0
    private var immersionSince: Date?

    mutating func reset() {
        activePressureCategory = nil
        immersionActive = false
        samples = []
        lastSampleAt = nil
        lowSince = nil
        highSince = nil
        immersionBaseline = nil
        immersionSampleCount = 0
        immersionSince = nil
    }

    mutating func expire(at now: Date) -> Bool {
        guard let lastSampleAt,
              now.timeIntervalSince(lastSampleAt) > 30 || now < lastSampleAt else { return false }
        reset()
        return true
    }

    mutating func evaluate(pressureHpa: Double, at time: Date, settings: EnvironmentalAlertSettings) {
        if let lastSampleAt, time.timeIntervalSince(lastSampleAt) > 30 || time < lastSampleAt {
            reset()
        }
        lastSampleAt = time
        evaluatePressure(pressureHpa, at: time, settings: settings)
        evaluateImmersion(pressureHpa, at: time, settings: settings)
    }

    private mutating func evaluatePressure(_ pressureHpa: Double, at time: Date, settings: EnvironmentalAlertSettings) {
        samples.append(pressureHpa)
        if samples.count > 5 {
            samples.removeFirst()
        }
        guard samples.count == 5 else { return }
        let mean = samples.reduce(0, +) / Double(samples.count)

        if settings.lowEnabled && mean <= settings.lowThresholdHpa {
            highSince = nil
            let since = lowSince ?? time
            lowSince = since
            activePressureCategory = time.timeIntervalSince(since) >= 10 ? .lowPressure : nil
        } else if settings.highEnabled && mean >= settings.highThresholdHpa {
            lowSince = nil
            let since = highSince ?? time
            highSince = since
            activePressureCategory = time.timeIntervalSince(since) >= 10 ? .highPressure : nil
        } else {
            lowSince = nil
            highSince = nil
            activePressureCategory = nil
        }
    }

    private mutating func evaluateImmersion(_ pressureHpa: Double, at time: Date, settings: EnvironmentalAlertSettings) {
        guard settings.immersionEnabled else {
            immersionBaseline = nil
            immersionSampleCount = 0
            immersionSince = nil
            immersionActive = false
            return
        }
        guard let baseline = immersionBaseline else {
            immersionBaseline = pressureHpa
            immersionSampleCount = 1
            return
        }
        guard immersionSampleCount >= 10 else {
            immersionBaseline = (baseline * Double(immersionSampleCount) + pressureHpa) / Double(immersionSampleCount + 1)
            immersionSampleCount += 1
            return
        }
        let rise = pressureHpa - baseline
        if rise >= 5 {
            let since = immersionSince ?? time
            immersionSince = since
            immersionActive = time.timeIntervalSince(since) >= 60
        } else if rise < 2 {
            immersionSince = nil
            immersionActive = false
            immersionBaseline = (baseline * 9 + pressureHpa) / 10
        }
    }
}
