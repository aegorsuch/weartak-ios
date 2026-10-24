import Foundation

@main
struct DistanceUnitsChecks {
    static func main() {
        let locale = Locale(identifier: "en_US_POSIX")
        func metric(_ meters: Double) -> String { DistanceUnits.metric.distance(meters, locale: locale) }
        func imperial(_ meters: Double) -> String { DistanceUnits.imperial.distance(meters, locale: locale) }
        precondition(metric(0) == "0 m")
        precondition(metric(50.9) == "50 m")
        precondition(metric(1_000) == "1000 m")
        precondition(metric(1_999.99) == "1999 m")
        precondition(metric(2_000) == "2.00 km")
        precondition(metric(12_345) == "12.35 km")
        precondition(imperial(0) == "0 ft")
        precondition(imperial(50) == "164 ft")
        precondition(imperial(1_609.343) == "5279 ft")
        precondition(imperial(1_609.344) == "1.00 mi")
        precondition(imperial(16_093.44) == "10.00 mi")
        precondition(DistanceUnits.metric.radius(50.9, locale: locale) == "51 m")
        precondition(DistanceUnits.imperial.radius(10, locale: locale) == "33 ft")
        precondition(DistanceUnits.imperial.radius(50, locale: locale) == "164 ft")
        precondition(DistanceUnits.metric.radius(2_000, locale: locale) == "2.00 km")
        precondition(DistanceUnits.imperial.radius(1_609.344, locale: locale) == "1.00 mi")
        for invalid in [-1.0, .nan, .infinity, -.infinity] {
            precondition(metric(invalid) == String(localized: "Distance unavailable"))
            precondition(imperial(invalid) == String(localized: "Distance unavailable"))
        }
        precondition(DistanceUnits.metric.distance(2_500, locale: Locale(identifier: "de_DE")) == "2,50 km")
        let name = "WearTAK.units-checks.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        func restored() -> DistanceUnits {
            defaults.string(forKey: DistanceUnits.storageKey).flatMap(DistanceUnits.init(rawValue:)) ?? .metric
        }
        precondition(restored() == .metric)
        defaults.set(DistanceUnits.imperial.rawValue, forKey: DistanceUnits.storageKey)
        precondition(restored() == .imperial)
        defaults.set(DistanceUnits.metric.rawValue, forKey: DistanceUnits.storageKey)
        precondition(restored() == .metric)
        let meterRadius = 50
        _ = DistanceUnits.imperial.radius(Double(meterRadius), locale: locale)
        precondition(meterRadius == 50, "Formatting must not change meter-backed proximity values")
        print("PASS: ATAK metric/imperial thresholds, truncation, precision, radius rounding, locale and persistence")
    }
}
