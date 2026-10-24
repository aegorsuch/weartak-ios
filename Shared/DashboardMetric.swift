import Foundation

enum DashboardMetric: String, CaseIterable, Identifiable {
    case exertion = "Exertion"
    case heartRate = "Heart Rate"
    case latLon = "Lat/Lon"
    case mgrs = "MGRS"

    var id: Self { self }
    var isCoordinate: Bool { self == .latLon || self == .mgrs }
    var symbol: String {
        switch self {
        case .exertion: return "figure.strengthtraining.traditional"
        case .heartRate: return "heart.fill"
        case .latLon: return "globe"
        case .mgrs: return "square.grid.3x3"
        }
    }

    static func restored(_ value: String?) -> Self {
        if value == "Lat/Long" { return .latLon }
        return value.flatMap(Self.init(rawValue:)) ?? .exertion
    }

    static func sorted(label: (Self) -> String) -> [Self] {
        allCases.sorted { label($0).localizedStandardCompare(label($1)) == .orderedAscending }
    }

    enum Reading: Equatable {
        case disabled, unavailable, value(Int)
    }

    func reading(monitoringEnabled: Bool, value: Int?, measuredAt: Date?, now: Date = Date()) -> Reading {
        guard !isCoordinate else { return .unavailable }
        guard monitoringEnabled else { return .disabled }
        guard let value, let measuredAt,
              (0...60).contains(now.timeIntervalSince(measuredAt)) else { return .unavailable }
        return .value(value)
    }
}
