import Foundation

/// Map preview never changes navigation. Hound toggles only the matching active identity.
enum BloodhoundPicker {
    enum Target: Equatable, Hashable, Identifiable {
        case route(String), marker(UUID), contact(String), point(String)

        var id: Self { self }
    }

    enum Action { case showOnMap, bloodhound }
    enum Command: Equatable {
        case showOnMap(Target), start(Target), chooseRoute(String), stop
    }

    static func command(for action: Action, target: Target, active: Target?) -> Command {
        switch action {
        case .showOnMap: return .showOnMap(target)
        case .bloodhound:
            if target == active { return .stop }
            if case .route(let id) = target { return .chooseRoute(id) }
            return .start(target)
        }
    }
}

/// Smallest longitude arc keeps route previews useful when a route crosses the date line.
struct BloodhoundMapBounds {
    let latitude: Double
    let longitude: Double
    let latitudeDelta: Double
    let longitudeDelta: Double

    init?(points: [GarminRoute.Point]) {
        guard !points.isEmpty, points.allSatisfy({
            $0.lat.isFinite && $0.lon.isFinite && (-90...90).contains($0.lat) && (-180...180).contains($0.lon)
        }) else { return nil }
        let latitudes = points.map(\.lat)
        let longitudes = points.map { ($0.lon + 360).truncatingRemainder(dividingBy: 360) }.sorted()
        var largestGap = -1.0
        var start = longitudes[0]
        for index in longitudes.indices {
            let next = index + 1 < longitudes.count ? longitudes[index + 1] : longitudes[0] + 360
            let gap = next - longitudes[index]
            if gap > largestGap {
                largestGap = gap
                start = next.truncatingRemainder(dividingBy: 360)
            }
        }
        let arc = 360 - largestGap
        let center = (start + arc / 2).truncatingRemainder(dividingBy: 360)
        latitude = (latitudes.min()! + latitudes.max()!) / 2
        longitude = center > 180 ? center - 360 : center
        latitudeDelta = min(180, max(0.01, (latitudes.max()! - latitudes.min()!) * 1.4))
        longitudeDelta = min(360, max(0.01, arc * 1.4))
    }
}
