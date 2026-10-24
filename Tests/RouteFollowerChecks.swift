import Foundation

@main
struct RouteFollowerChecks {
    static func main() {
        typealias Point = GarminRoute.Point
        func point(_ lat: Double, _ lon: Double = 0, name: String? = nil) -> Point {
            Point(lat: lat, lon: lon, name: name)
        }
        func route(_ points: [Point], server: String = "server") -> GarminRoute {
            GarminRoute(serverId: server, uid: "route", name: "Test route", points: points)
        }
        func near(_ actual: Double?, _ expected: Double, tolerance: Double = 0.01) {
            precondition(actual != nil && abs(actual! - expected) < tolerance)
        }

        let geometry = [point(0, name: "Beginning"), point(0.001), point(0.002, name: "End")]
        let value = route(geometry)
        var beginning = RouteFollower(route: value, start: .beginning, location: nil)!
        precondition(beginning.targetIndex == 0 && beginning.points == geometry)
        precondition(beginning.routeID == value.id && !beginning.isComplete)
        precondition(RouteFollower.arrivalRadiusMeters(method: nil) == 20)
        precondition(RouteFollower(route: value, start: .nearest, location: nil) == nil)
        precondition(RouteFollower(route: value, start: .nearest, location: point(.nan)) == nil)
        precondition(RouteFollower(route: route([]), start: .beginning, location: nil) == nil)
        precondition(RouteFollower.nearestIndex(in: [], to: point(0)) == nil)
        precondition(RouteFollower.nearestIndex(in: geometry, to: point(91)) == nil)
        precondition(RouteFollower.nearestIndex(in: geometry, to: point(0, 181)) == nil)
        precondition(RouteFollower.nearestIndex(in: geometry, to: point(.infinity)) == nil)
        precondition(RouteFollower.nearestIndex(in: [point(-1), point(1)], to: point(0)) == 0)
        precondition(RouteFollower.nearestIndex(in: [point(0, 179), point(0, -179.9)], to: point(0, 179.95)) == 1)

        var nearest = RouteFollower(route: value, start: .nearest, location: point(0.0011))!
        precondition(nearest.targetIndex == 1, "Nearest must retain the unnamed vertex's original index")
        nearest.advance(at: point(0.0011))
        precondition(nearest.targetIndex == 2)
        nearest.advance(at: point(0))
        precondition(nearest.targetIndex == 2, "Following must never go backwards")
        nearest.advance(at: point(0.002))
        precondition(nearest.isComplete)
        near(nearest.remainingDistanceMeters(from: point(0.002)), 0)
        nearest.advance(at: point(0.002))
        precondition(nearest.targetIndex == geometry.count, "Completion is stable and cannot index past the end")

        beginning.advance(at: point(-0.001))
        precondition(beginning.targetIndex == 0)
        beginning.advance(at: point(.nan))
        precondition(beginning.targetIndex == 0)
        beginning.advance(at: point(0))
        precondition(beginning.targetIndex == 1)
        precondition(beginning.remainingDistanceMeters(from: point(.nan)) == nil)
        near(beginning.remainingDistanceMeters(from: point(0)), 222.38985)
        let bent = route([point(0), point(0.001), point(0.001, 0.001)])
        let bentFollow = RouteFollower(route: bent, start: .beginning, location: nil)!
        near(bentFollow.remainingDistanceMeters(from: point(-0.001)), 333.58478)

        let dense = route([point(0), point(0), point(0.00005), point(0.0001), point(0.001)])
        var denseFollow = RouteFollower(route: dense, start: .beginning, location: nil)!
        denseFollow.advance(at: point(0))
        precondition(denseFollow.targetIndex == 4, "Skip all consecutive points inside 20 m in one fix")
        denseFollow.advance(at: point(0.001))
        precondition(denseFollow.isComplete)
        var colocated = RouteFollower(route: route([point(0), point(0)]), start: .beginning, location: nil)!
        colocated.advance(at: point(0))
        precondition(colocated.isComplete, "A route may finish immediately when every remaining point is nearby")

        let metersToDegrees = 180 / (Double.pi * 6_371_000)
        var outside = RouteFollower(route: value, start: .beginning, location: nil)!
        outside.advance(at: point(-20.01 * metersToDegrees))
        precondition(outside.targetIndex == 0)
        outside.advance(at: point(-19.99 * metersToDegrees))
        precondition(outside.targetIndex == 1)
        // A later vertex near the user must not skip an earlier, unvisited distant target.
        var ordered = RouteFollower(route: route([point(0.01), point(0)]), start: .beginning, location: nil)!
        ordered.advance(at: point(0))
        precondition(ordered.targetIndex == 0)
        let one = route([point(0)])
        var single = RouteFollower(route: one, start: .beginning, location: nil)!
        single.advance(at: point(0))
        precondition(single.isComplete)
        let otherServer = RouteFollower(route: route(geometry, server: "other"), start: .beginning, location: nil)!
        precondition(otherServer.routeID != beginning.routeID)
        for (method, radius) in [("Walking", 10.0), ("Swimming", 10), ("Driving", 20),
                                 ("Watercraft", 100), ("Flying", 1_000), ("Unknown", 20)] {
            var methodRoute = route([point(0), point(0.1)])
            methodRoute.method = method
            var follower = RouteFollower(route: methodRoute, start: .beginning, location: nil)!
            precondition(follower.arrivalRadiusMeters == radius)
            follower.advance(at: point(-(radius + 0.01) * metersToDegrees))
            precondition(follower.targetIndex == 0, "\(method) must not arrive outside its radius")
            follower.advance(at: point(-(radius - 0.01) * metersToDegrees))
            precondition(follower.targetIndex == 1, "\(method) must arrive inside its radius")
            let restored = RouteFollower(route: methodRoute, targetIndex: 1)!
            precondition(restored.targetIndex == 1 && restored.arrivalRadiusMeters == radius)
        }
        precondition(RouteFollower(route: value, targetIndex: -1) == nil)
        precondition(RouteFollower(route: value, targetIndex: 4) == nil)
        print("PASS: route start modes, original indices, nearest vertex, ordered/dense arrival, completion, remaining distance")
    }
}
