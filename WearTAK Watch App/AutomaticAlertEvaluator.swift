import Foundation

enum AutomaticAlertCategory: String {
    case highRestingHeartRate = "High resting heart rate"
    case lowRestingHeartRate = "Low resting heart rate"
    case highExertion = "High exertion"

    var requiredDuration: TimeInterval {
        self == .highExertion ? 120 : 600
    }
}

enum MovementState {
    case unknown
    case stationary
    case moving
}

struct AutomaticAlertEvaluator {
    private(set) var activeCategory: AutomaticAlertCategory?
    private(set) var warningCategory: AutomaticAlertCategory?
    private var candidateCategory: AutomaticAlertCategory?
    private var candidateSince: Date?
    private var lastSampleAt: Date?

    mutating func reset() {
        activeCategory = nil
        warningCategory = nil
        candidateCategory = nil
        candidateSince = nil
        lastSampleAt = nil
    }

    mutating func expire(at now: Date) {
        if let lastSampleAt, now.timeIntervalSince(lastSampleAt) > 60 || now < lastSampleAt {
            reset()
        }
    }

    mutating func evaluate(heartRate: Double, at time: Date, movement: MovementState, age: Int?) {
        guard heartRate > 0, let previous = lastSampleAt, time > previous,
              time.timeIntervalSince(previous) <= 60 else {
            reset()
            lastSampleAt = time
            return
        }
        lastSampleAt = time

        let category: AutomaticAlertCategory?
        switch movement {
        case .unknown:
            category = nil
        case .stationary:
            if heartRate >= 120 {
                category = .highRestingHeartRate
            } else if heartRate <= 40 {
                category = .lowRestingHeartRate
            } else {
                category = nil
            }
        case .moving:
            if let age, (18...100).contains(age),
               heartRate / (208 - 0.7 * Double(age)) >= 0.9 {
                category = .highExertion
            } else {
                category = nil
            }
        }

        guard let category else {
            candidateCategory = nil
            candidateSince = nil
            activeCategory = nil
            warningCategory = nil
            return
        }
        if candidateCategory != category {
            candidateCategory = category
            candidateSince = time
            activeCategory = nil
            warningCategory = nil
        }
        guard let candidateSince else { return }
        let elapsed = time.timeIntervalSince(candidateSince)
        if category != .highExertion && elapsed >= 300 {
            warningCategory = category
        }
        if elapsed >= category.requiredDuration {
            activeCategory = category
        }
    }
}