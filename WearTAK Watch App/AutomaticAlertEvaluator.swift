import Foundation

enum AutomaticAlertCategory: String {
    case highRestingHeartRate = "High resting heart rate"
    case lowRestingHeartRate = "Low resting heart rate"
    case highExertion = "High exertion"
}

enum MovementState {
    case unknown
    case stationary
    case moving
}

struct AutomaticAlertThresholds {
    var highResting: Double
    var lowResting: Double
    var exertionWarningFraction: Double
    var exertionAlertFraction: Double
    var highRestingWarningDuration: TimeInterval
    var highRestingAlertDuration: TimeInterval
    var lowRestingWarningDuration: TimeInterval
    var lowRestingAlertDuration: TimeInterval
    var exertionWarningDuration: TimeInterval
    var exertionAlertDuration: TimeInterval
}

struct AutomaticAlertEvaluator {
    private(set) var activeCategory: AutomaticAlertCategory?
    private(set) var warningCategory: AutomaticAlertCategory?

    private var restingCandidate: AutomaticAlertCategory?
    private var restingCandidateSince: Date?
    private var exertionWarningSince: Date?
    private var exertionAlertSince: Date?
    private var lastSampleAt: Date?

    mutating func reset() {
        activeCategory = nil
        warningCategory = nil
        restingCandidate = nil
        restingCandidateSince = nil
        exertionWarningSince = nil
        exertionAlertSince = nil
        lastSampleAt = nil
    }

    mutating func expire(at now: Date) {
        if let lastSampleAt, now.timeIntervalSince(lastSampleAt) > 60 || now < lastSampleAt {
            reset()
        }
    }

    mutating func evaluate(
        heartRate: Double, at time: Date, movement: MovementState, age: Int?,
        thresholds: AutomaticAlertThresholds
    ) {
        guard heartRate > 0 else {
            reset()
            return
        }
        if let previous = lastSampleAt,
           (time <= previous || time.timeIntervalSince(previous) > 60) {
            reset()
        }
        lastSampleAt = time

        switch movement {
        case .unknown:
            restingCandidate = nil
            restingCandidateSince = nil
            exertionWarningSince = nil
            exertionAlertSince = nil
            activeCategory = nil
            warningCategory = nil
        case .stationary:
            exertionWarningSince = nil
            exertionAlertSince = nil
            evaluateResting(heartRate: heartRate, at: time, thresholds: thresholds)
        case .moving:
            restingCandidate = nil
            restingCandidateSince = nil
            evaluateExertion(heartRate: heartRate, at: time, age: age, thresholds: thresholds)
        }
    }

    private mutating func evaluateResting(heartRate: Double, at time: Date, thresholds: AutomaticAlertThresholds) {
        let category: AutomaticAlertCategory?
        if heartRate >= thresholds.highResting {
            category = .highRestingHeartRate
        } else if heartRate <= thresholds.lowResting {
            category = .lowRestingHeartRate
        } else {
            category = nil
        }
        guard let category else {
            restingCandidate = nil
            restingCandidateSince = nil
            activeCategory = nil
            warningCategory = nil
            return
        }
        if restingCandidate != category {
            restingCandidate = category
            restingCandidateSince = time
            activeCategory = nil
            warningCategory = nil
        }
        guard let since = restingCandidateSince else { return }
        let elapsed = time.timeIntervalSince(since)
        let warningDuration = category == .highRestingHeartRate
            ? thresholds.highRestingWarningDuration : thresholds.lowRestingWarningDuration
        let alertDuration = category == .highRestingHeartRate
            ? thresholds.highRestingAlertDuration : thresholds.lowRestingAlertDuration
        warningCategory = elapsed >= warningDuration ? category : nil
        activeCategory = elapsed >= alertDuration ? category : nil
    }

    // Garmin times exertion warning and alert from independent threshold crossings, not a shared timer.
    private mutating func evaluateExertion(
        heartRate: Double, at time: Date, age: Int?, thresholds: AutomaticAlertThresholds
    ) {
        guard let age, (18...100).contains(age) else {
            exertionWarningSince = nil
            exertionAlertSince = nil
            activeCategory = nil
            warningCategory = nil
            return
        }
        let percent = heartRate / (208 - 0.7 * Double(age))

        exertionAlertSince = percent >= thresholds.exertionAlertFraction ? (exertionAlertSince ?? time) : nil
        exertionWarningSince = percent >= thresholds.exertionWarningFraction ? (exertionWarningSince ?? time) : nil

        if let since = exertionWarningSince, time.timeIntervalSince(since) >= thresholds.exertionWarningDuration {
            warningCategory = .highExertion
        } else {
            warningCategory = nil
        }
        if let since = exertionAlertSince, time.timeIntervalSince(since) >= thresholds.exertionAlertDuration {
            activeCategory = .highExertion
        } else {
            activeCategory = nil
        }
    }
}