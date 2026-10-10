import Foundation

struct UserMetrics: Codable, Equatable, Identifiable {
    enum Field: String, CaseIterable, Identifiable {
        case birthYear, heightCM, weightKG, sex, bloodType
        var id: String { rawValue }
        var title: String {
            switch self {
            case .birthYear: return "Birth year"
            case .heightCM: return "Height (cm)"
            case .weightKG: return "Weight (kg)"
            case .sex: return "Sex"
            case .bloodType: return "Blood type"
            }
        }
    }

    var birthYear: Int?
    var heightCM: Double?
    var weightKG: Double?
    var sex: String?
    var bloodType: String?
    var source: String
    var measuredAt: Date?
    var id: String { "\(source):\(measuredAt?.timeIntervalSince1970 ?? 0)" }

    private enum CodingKeys: String, CodingKey {
        case birthYear, heightCM, weightKG, sex, bloodType, source, measuredAt
    }

    func value(_ field: Field) -> String? {
        switch field {
        case .birthYear: return birthYear.map(String.init)
        case .heightCM: return heightCM.map { String(format: "%.1f", $0) }
        case .weightKG: return weightKG.map { String(format: "%.1f", $0) }
        case .sex: return sex
        case .bloodType: return bloodType
        }
    }

    func validated(now: Date = Date()) throws -> Self {
        if let birthYear, !(1900...Calendar.current.component(.year, from: now)).contains(birthYear) {
            throw Failure.invalid("birth year")
        }
        if let heightCM, !heightCM.isFinite || !(30...275).contains(heightCM) { throw Failure.invalid("height") }
        if let weightKG, !weightKG.isFinite || !(1...500).contains(weightKG) { throw Failure.invalid("weight") }
        if let sex, !["Male", "Female", "Other", "Not Set"].contains(sex) { throw Failure.invalid("sex") }
        if let bloodType, !["A+", "A-", "B+", "B-", "AB+", "AB-", "O+", "O-", "Unknown"].contains(bloodType) {
            throw Failure.invalid("blood type")
        }
        return self
    }

    mutating func importFields(_ fields: Set<Field>, from preview: Self) {
        if fields.contains(.birthYear), let value = preview.birthYear { birthYear = value }
        if fields.contains(.heightCM), let value = preview.heightCM { heightCM = value }
        if fields.contains(.weightKG), let value = preview.weightKG { weightKG = value }
        if fields.contains(.sex), let value = preview.sex { sex = value }
        if fields.contains(.bloodType), let value = preview.bloodType { bloodType = value }
        source = preview.source
        measuredAt = preview.measuredAt
    }

    enum Failure: LocalizedError {
        case invalid(String), unavailable
        var errorDescription: String? {
            switch self {
            case .invalid(let field): return "The imported \(field) is outside the supported range."
            case .unavailable: return "No readable user metrics are available. Check your profile and Health permissions."
            }
        }
    }
}
