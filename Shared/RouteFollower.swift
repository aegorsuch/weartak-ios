import Foundation

/// Standalone checkpoint following over full, unrenumbered route geometry.
struct RouteFollower: Equatable {
    static func arrivalRadiusMeters(method: String?) -> Double {
        switch method?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "walking", "walk", "swimming", "swim": return 10
        case "watercraft": return 100
        case "flying": return 1_000
        case "driving": return 20
        default: return 10
        }
    }

    enum Start { case beginning, nearest }

    let routeID: String
    let points: [GarminRoute.Point]
    let arrivalRadiusMeters: Double
    let checkpointIndices: [Int]
    private(set) var targetIndex: Int
    private(set) var arrivedIndices: Set<Int> = []
    var isComplete: Bool { targetIndex == points.count }

    init?(route: GarminRoute, start: Start, location: GarminRoute.Point?) {
        let checkpoints = route.navigationIndices
        guard !checkpoints.isEmpty else { return nil }
        let index: Int
        switch start {
        case .beginning: index = checkpoints[0]
        case .nearest:
            guard let location, let projection = Self.projectedDistance(in: route.points, to: location) else { return nil }
            let distances = Self.vertexDistances(route.points)
            index = checkpoints.first { distances[$0] >= projection } ?? checkpoints.last!
        }
        routeID = route.id
        points = route.points
        arrivalRadiusMeters = Self.arrivalRadiusMeters(method: route.method)
        checkpointIndices = checkpoints
        targetIndex = index
    }

    init?(route: GarminRoute, targetIndex: Int, arrivedIndices: Set<Int> = []) {
        let checkpoints = route.navigationIndices
        guard !checkpoints.isEmpty, targetIndex == route.points.count || checkpoints.contains(targetIndex) else { return nil }
        routeID = route.id
        points = route.points
        arrivalRadiusMeters = Self.arrivalRadiusMeters(method: route.method)
        checkpointIndices = checkpoints
        self.targetIndex = targetIndex
        self.arrivedIndices = arrivedIndices
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

    mutating func advance(at location: GarminRoute.Point, accuracyMeters: Double = 0) {
        guard Self.usable(location),
              let projection = Self.projectedDistance(in: points, to: location) else { return }
        guard !isComplete else { return }
        let accuracy = accuracyMeters.isFinite && accuracyMeters >= 0 ? accuracyMeters : 0
        let radius = arrivalRadiusMeters + accuracy
        let distances = Self.vertexDistances(points)
        for index in points.indices where points[index].isCheckpoint &&
            Self.distanceMeters(from: location, to: points[index]) <= radius {
            arrivedIndices.insert(index)
        }
        if Self.distanceMeters(from: location, to: points.last!) <= radius {
            targetIndex = points.count
            return
        }
        while !isComplete && arrivedIndices.contains(targetIndex) {
            guard let position = checkpointIndices.firstIndex(of: targetIndex) else { return }
            guard position < checkpointIndices.count - 1 else { return }
            guard projection >= distances[targetIndex] else { return }
            targetIndex = checkpointIndices[position + 1]
        }
    }

    /// Distance to the target plus every remaining leg, not a shortcut to the end.
    func remainingDistanceMeters(from location: GarminRoute.Point) -> Double? {
        guard Self.usable(location) else { return nil }
        guard !isComplete else { return 0 }
        var distance = Self.distanceMeters(from: location, to: points[targetIndex])
        for index in points.indices where index > targetIndex && index <= checkpointIndices.last! {
            distance += Self.distanceMeters(from: points[index - 1], to: points[index])
        }
        return distance
    }

    /// Local tangent-plane segment projection; strict ties keep the earliest segment.
    /// Longitude deltas wrap so a date-line crossing is not treated as a world-spanning leg.
    static func projectedDistance(in points: [GarminRoute.Point], to location: GarminRoute.Point) -> Double? {
        guard usable(location), !points.isEmpty, points.allSatisfy(usable) else { return nil }
        if points.count == 1 { return 0 }
        var closest = Double.infinity
        var along = 0.0
        var travelled = 0.0
        let scale = cos(location.lat * Double.pi / 180)
        for index in 1..<points.count {
            let start = points[index - 1], end = points[index]
            let ax = wrappedLongitude(start.lon - location.lon) * scale
            let ay = start.lat - location.lat
            let dx = wrappedLongitude(end.lon - start.lon) * scale
            let dy = end.lat - start.lat
            let lengthSquared = dx * dx + dy * dy
            let fraction = lengthSquared > 0 ? min(1, max(0, -(ax * dx + ay * dy) / lengthSquared)) : 0
            let distance = pow(ax + fraction * dx, 2) + pow(ay + fraction * dy, 2)
            let length = distanceMeters(from: start, to: end)
            if distance < closest {
                closest = distance
                along = travelled + fraction * length
            }
            travelled += length
        }
        return along
    }

    private static func vertexDistances(_ points: [GarminRoute.Point]) -> [Double] {
        var distances = [0.0]
        for index in points.indices.dropFirst() {
            distances.append(distances.last! + distanceMeters(from: points[index - 1], to: points[index]))
        }
        return distances
    }

    private static func wrappedLongitude(_ value: Double) -> Double {
        let wrapped = (value + 180).truncatingRemainder(dividingBy: 360)
        return (wrapped < 0 ? wrapped + 360 : wrapped) - 180
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
