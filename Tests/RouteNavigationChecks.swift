import Foundation

@main
struct RouteNavigationChecks {
    static func main() throws {
        let route = GarminRoute(serverId: "server", uid: "route", name: "Navigation",
            points: [.init(lat: 0, lon: 0, name: "Start"), .init(lat: 0.001, lon: 0),
                     .init(lat: 0.002, lon: 0, name: "End")], method: "Walking")
        var phone = RouteNavigationReplica()
        var watch = RouteNavigationReplica()
        try phone.start(route: route, start: .beginning, location: nil, origin: "phone")
        let start = phone.state!
        let receivedStart = try watch.receive(RouteNavigationState.decode(start.encoded()))
        precondition(receivedStart && watch.state == phone.state)
        precondition(watch.state?.route.points == route.points, "Full raw geometry must travel with the session")
        precondition(watch.advance(at: route.points[0], origin: "watch"))
        let receivedWatchProgress = try phone.receive(watch.state!)
        precondition(receivedWatchProgress && phone.state?.targetIndex == 1)
        precondition(phone.advance(at: route.points[1], origin: "phone"))
        let receivedPhoneProgress = try watch.receive(phone.state!)
        precondition(receivedPhoneProgress && watch.state?.targetIndex == 2)
        let staleStart = try watch.receive(start)
        precondition(!staleStart && watch.state?.targetIndex == 2, "Late context cannot regress progress")
        let beforeStop = phone.state!
        precondition(watch.stop(origin: "watch"))
        let receivedStop = try phone.receive(watch.state!)
        precondition(receivedStop && phone.state?.phase == .stopped)
        let staleProgress = try phone.receive(beforeStop)
        precondition(!staleProgress && phone.state?.phase == .stopped, "Stop is a terminal tombstone")
        precondition(!phone.advance(at: route.points[2], origin: "phone"))

        // Reverse start, resume after process death, and completion in the other direction.
        try watch.start(route: route, start: .nearest, location: route.points[1], origin: "watch")
        let reverseStart = try phone.receive(watch.state!)
        precondition(reverseStart && phone.state?.targetIndex == 2)
        var restored = RouteNavigationReplica()
        let restoredStart = try restored.receive(RouteNavigationState.decode(phone.state!.encoded()))
        precondition(restoredStart && restored.state == phone.state)
        precondition(restored.advance(at: route.points[2], origin: "phone"))
        let completion = try watch.receive(restored.state!)
        precondition(completion && watch.state?.phase == .completed && watch.state?.targetIndex == 3)
        let lateProgress = try watch.receive(phone.state!)
        precondition(!lateProgress && watch.state?.phase == .completed)
        let oldSession = try watch.receive(beforeStop)
        precondition(!oldSession, "Old sessions cannot replace a newer start")

        // Simultaneous starts and reordered updates converge identically on both devices.
        var a = RouteNavigationReplica(), b = RouteNavigationReplica()
        try a.start(route: route, start: .beginning, location: nil, origin: "phone")
        try b.start(route: route, start: .beginning, location: nil, origin: "watch")
        let aStart = a.state!, bStart = b.state!
        _ = try a.receive(bStart)
        _ = try b.receive(aStart)
        precondition(a.state == b.state)
        precondition(a.advance(at: route.points[0], origin: "phone"))
        _ = try b.receive(a.state!)
        let active = a.state!
        precondition(a.advance(at: route.points[1], origin: "phone"))
        precondition(b.stop(origin: "watch"))
        let progressing = a.state!, stopped = b.state!
        _ = try a.receive(stopped)
        _ = try b.receive(progressing)
        _ = try b.receive(a.state!)
        precondition(a.state == b.state && a.state?.phase == .stopped,
                     "Concurrent stop must win against in-flight progress")
        _ = try a.receive(active)
        precondition(a.state?.phase == .stopped)

        var invalid = start
        invalid.targetIndex = -1
        expectInvalid { _ = try invalid.encoded() }
        invalid = start
        invalid.targetIndex = route.points.count
        expectInvalid { _ = try invalid.validated() }
        invalid = start
        invalid.phase = .completed
        expectInvalid { _ = try invalid.validated() }
        invalid = start
        invalid.version = 2
        expectInvalid { _ = try invalid.validated() }
        expectInvalid { _ = try RouteNavigationState.decode(Data(repeating: 0, count: 16_001)) }
        expectInvalid { _ = try RouteNavigationState.decode(Data("{}".utf8)) }
        var noGPS = RouteNavigationReplica()
        expectInvalid { try noGPS.start(route: route, start: .nearest, location: nil, origin: "phone") }
        precondition(noGPS.state == nil)

        let xml = """
        <event uid="route" type="b-m-r"><detail><contact callsign="Walking"/>
        <link_attr method="Walking"/><link relation="c" point="0,0" callsign="Start"/>
        <link relation="c" point="0.001,0"/><link relation="c" point="0.002,0" callsign="End"/>
        </detail></event>
        """
        let events = try GarminRouteCoT.parse(Data(xml.utf8), serverId: "server")
        guard case .route(let parsed) = events.first else { preconditionFailure("Route method not parsed") }
        precondition(parsed.method == "Walking" && parsed.points.count == 3 && parsed.namedPoints.count == 2)
        let roundTrip = try JSONDecoder().decode(GarminRoute.self, from: JSONEncoder().encode(parsed))
        precondition(roundTrip.method == "Walking")
        var oldRoute = parsed
        oldRoute.method = nil
        let oldData = try JSONEncoder().encode(oldRoute)
        let oldDecoded = try JSONDecoder().decode(GarminRoute.self, from: oldData)
        precondition(oldDecoded.method == nil)

        var routes = WatchRoutes()
        var copy = route
        copy = GarminRoute(serverId: "other", uid: route.uid, name: route.name, points: route.points)
        let different = GarminRoute(serverId: "server", uid: "different", name: "Other", points: Array(route.points.prefix(2)))
        try routes.replace([route, copy, different])
        routes.remove(route)
        precondition(routes.routes == [different], "Local route removal clears all source copies of the UID")
        routes.removeAll()
        precondition(routes.routes.isEmpty, "Remove All must clear routes as well as ordinary points")
        print("PASS: two-way starts/progress/stop/completion, restart/replay/conflicts, method metadata, local route removal")
    }

    private static func expectInvalid(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Invalid navigation data was accepted") }
        catch {}
    }
}
