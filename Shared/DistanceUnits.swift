import Foundation

/// Display-only preference. CoT, route geometry and proximity calculations always use meters.
enum DistanceUnits: String, CaseIterable, Identifiable {
    case metric = "Metric"
    case imperial = "Imperial"

    static let storageKey = "WearTAK.distanceUnits"
    var id: Self { self }

    var title: String {
        switch self {
        case .metric: return String(localized: "Metric")
        case .imperial: return String(localized: "Imperial")
        }
    }

    func distance(_ meters: Double, locale: Locale = .current) -> String {
        format(meters, rounding: .towardZero, locale: locale)
    }

    func radius(_ meters: Double, locale: Locale = .current) -> String {
        format(meters, rounding: .toNearestOrAwayFromZero, locale: locale)
    }

    private func format(_ meters: Double, rounding: FloatingPointRoundingRule, locale: Locale) -> String {
        guard meters.isFinite, meters >= 0 else { return String(localized: "Distance unavailable") }
        switch self {
        case .metric:
            // ATAK defaults: rng_meters_display_pref=2000, rng_feet_display_pref=5280.
            if meters >= 2_000 { return String(format: "%.2f km", locale: locale, meters / 1_000) }
            return String(format: "%.0f m", locale: locale, meters.rounded(rounding))
        case .imperial:
            if meters >= 1_609.344 { return String(format: "%.2f mi", locale: locale, meters / 1_609.344) }
            return String(format: "%.0f ft", locale: locale, (meters / 0.3048).rounded(rounding))
        }
    }
}
