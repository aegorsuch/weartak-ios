import Foundation

/// A paired-device session carries full geometry, including unnamed vertices. Terminal states
/// remain as tombstones so delayed application contexts cannot restart a stopped route.
struct RouteNavigationState: Codable, Equatable {
    nonisolated static let contextKey = "WearTAK.routeNavigation"
    static let storageKey = "WearTAK.routeNavigationState"
    enum Phase: String, Codable { case active, stopped, completed }

    var version = 1
    let sessionID: UUID
    let startClock: Int
    let startOrigin: String
    var clock: Int
    var origin: String
    let route: GarminRoute
    var targetIndex: Int
    var phase: Phase

    func validated() throws -> Self {
        _ = try route.validated()
        guard version == 1, startClock > 0, clock >= startClock, clock < Int.max - 1,
              ["phone", "watch"].contains(startOrigin), ["phone", "watch"].contains(origin),
              (0...route.points.count).contains(targetIndex),
              phase != .active || targetIndex < route.points.count,
              phase != .completed || targetIndex == route.points.count else { throw Failure.invalid }
        return self
    }

    func encoded() throws -> Data {
        _ = try validated()
        let data = try JSONEncoder().encode(self)
        guard data.count <= 16_000 else { throw Failure.invalid }
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16_000 else { throw Failure.invalid }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }

    enum Failure: LocalizedError {
        case invalid
        var errorDescription: String? { "Route navigation state is invalid. Update both WearTAK apps and retry." }
    }
}

/// Logical clocks order starts without relying on synchronized wall clocks. Within a session,
/// progress only moves forwards and stop/completion beats any in-flight active update.
struct RouteNavigationReplica {
    private(set) var state: RouteNavigationState?

    @discardableResult
    mutating func receive(_ incoming: RouteNavigationState) throws -> Bool {
        let incoming = try incoming.validated()
        if let current = state {
            if incoming.sessionID == current.sessionID {
                guard incoming.route == current.route, incoming.startClock == current.startClock,
                      incoming.startOrigin == current.startOrigin else { throw RouteNavigationState.Failure.invalid }
                if current.phase != .active && incoming.phase == .active { return false }
                if current.phase == .active && incoming.phase == .active {
                    if incoming.targetIndex < current.targetIndex { return false }
                    if incoming.targetIndex == current.targetIndex && !Self.newer(incoming, than: current) { return false }
                } else if current.phase != .active && incoming.phase != .active && !Self.newer(incoming, than: current) {
                    return false
                }
            } else {
                let incomingStart = (incoming.startClock, incoming.startOrigin, incoming.sessionID.uuidString)
                let currentStart = (current.startClock, current.startOrigin, current.sessionID.uuidString)
                guard incomingStart > currentStart else { return false }
            }
        }
        guard state != incoming else { return false }
        var merged = incoming
        if let current = state, current.sessionID == incoming.sessionID, Self.newer(current, than: incoming) {
            merged.clock = current.clock
            merged.origin = current.origin
        }
        state = merged
        return true
    }

    mutating func start(route: GarminRoute, start: RouteFollower.Start,
                        location: GarminRoute.Point?, origin: String) throws {
        _ = try route.validated()
        guard var follower = RouteFollower(route: route, start: start, location: location) else {
            throw RouteNavigationState.Failure.invalid
        }
        if let location { follower.advance(at: location) }
        let clock = (state?.clock ?? 0) + 1
        state = try RouteNavigationState(sessionID: UUID(), startClock: clock, startOrigin: origin,
            clock: clock, origin: origin, route: route, targetIndex: follower.targetIndex,
            phase: follower.isComplete ? .completed : .active).validated()
    }

    @discardableResult
    mutating func advance(at location: GarminRoute.Point, origin: String) -> Bool {
        guard var current = state, current.phase == .active,
              var follower = RouteFollower(route: current.route, targetIndex: current.targetIndex) else { return false }
        follower.advance(at: location)
        guard follower.targetIndex != current.targetIndex else { return false }
        current.targetIndex = follower.targetIndex
        current.phase = follower.isComplete ? .completed : .active
        current.clock += 1
        current.origin = origin
        state = current
        return true
    }

    @discardableResult
    mutating func stop(origin: String) -> Bool {
        guard var current = state, current.phase == .active else { return false }
        current.phase = .stopped
        current.clock += 1
        current.origin = origin
        state = current
        return true
    }

    private static func newer(_ lhs: RouteNavigationState, than rhs: RouteNavigationState) -> Bool {
        (lhs.clock, lhs.origin) > (rhs.clock, rhs.origin)
    }
}
