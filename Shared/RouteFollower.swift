import Foundation

/// Local, ordered vertex navigation. Never filters or renumbers unnamed geometry.
struct RouteFollower: Equatable {
    static func arrivalRadiusMeters(method: String?) -> Double {
        switch method?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "walking", "walk", "swimming", "swim": return 10
        case "watercraft": return 100
        case "flying": return 1_000
        default: return 20
        }
    }

    enum Start { case beginning, nearest }

    let routeID: String
    let points: [GarminRoute.Point]
    let arrivalRadiusMeters: Double
    private(set) var targetIndex: Int
    var isComplete: Bool { targetIndex == points.count }

    init?(route: GarminRoute, start: Start, location: GarminRoute.Point?) {
        guard !route.points.isEmpty else { return nil }
        let index: Int
        switch start {
        case .beginning: index = 0
        case .nearest:
            guard let location, let nearest = Self.nearestIndex(in: route.points, to: location) else { return nil }
            index = nearest
        }
        routeID = route.id
        points = route.points
        arrivalRadiusMeters = Self.arrivalRadiusMeters(method: route.method)
        targetIndex = index
    }

    init?(route: GarminRoute, targetIndex: Int) {
        guard !route.points.isEmpty, (0...route.points.count).contains(targetIndex) else { return nil }
        routeID = route.id
        points = route.points
        arrivalRadiusMeters = Self.arrivalRadiusMeters(method: route.method)
        self.targetIndex = targetIndex
    }

    static func nearestIndex(in points: [GarminRoute.Point], to location: GarminRoute.Point) -> Int? {
        guard usable(location) else { return nil }
        var nearest: Int?
        var minimum = Double.infinity
        for (index, point) in points.enumerated() where usable(point) {
            let distance = distanceMeters(from: location, to: point)
            // Strict comparison keeps the first vertex when distances tie.
            if distance < minimum { nearest = index; minimum = distance }
        }
        return nearest
    }

    mutating func advance(at location: GarminRoute.Point) {
        guard Self.usable(location) else { return }
        while !isComplete && Self.distanceMeters(from: location, to: points[targetIndex]) <= arrivalRadiusMeters {
            targetIndex += 1
        }
    }

    /// Distance to the target plus every remaining leg, not a shortcut to the end.
    func remainingDistanceMeters(from location: GarminRoute.Point) -> Double? {
        guard Self.usable(location) else { return nil }
        guard !isComplete else { return 0 }
        var distance = Self.distanceMeters(from: location, to: points[targetIndex])
        for index in points.indices where index > targetIndex {
            distance += Self.distanceMeters(from: points[index - 1], to: points[index])
        }
        return distance
    }

    static func distanceMeters(from start: GarminRoute.Point, to end: GarminRoute.Point) -> Double {
        let radians = Double.pi / 180
        let lat1 = start.lat * radians, lat2 = end.lat * radians
        let dLat = (end.lat - start.lat) * radians
        let dLon = (end.lon - start.lon) * radians
        let a = pow(sin(dLat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dLon / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, a))))
    }

    private static func usable(_ point: GarminRoute.Point) -> Bool {
        point.lat.isFinite && point.lon.isFinite && (-90...90).contains(point.lat) && (-180...180).contains(point.lon)
    }
}
