import Foundation

@main
struct RouteFollowerChecks {
    static func main() {
        typealias Point = GarminRoute.Point
        let degreesPerMeter = 180 / (Double.pi * 6_371_000)
        func point(_ meters: Double, checkpoint: Bool = true) -> Point {
            Point(lat: meters * degreesPerMeter, lon: 0, type: checkpoint ? "b-m-p-w" : "b-m-p-c")
        }
        func route(_ points: [Point], method: String? = "Driving", server: String = "server") -> GarminRoute {
            GarminRoute(serverId: server, uid: "route", name: "Test route", points: points, method: method)
        }
        func near(_ actual: Double?, _ expected: Double, tolerance: Double = 0.01) {
            precondition(actual != nil && abs(actual! - expected) < tolerance)
        }
        let geometry = [point(0), point(100), point(200)]
        let value = route(geometry)
        var beginning = RouteFollower(route: value, start: .beginning, location: nil)!
        precondition(beginning.targetIndex == 0 && beginning.points == geometry)
        precondition(beginning.routeID == value.id && !beginning.isComplete)
        precondition(RouteFollower.arrivalRadiusMeters(method: nil) == 10)
        precondition(RouteFollower(route: value, start: .nearest, location: nil) == nil)
        precondition(RouteFollower(route: value, start: .nearest, location: .init(lat: .nan, lon: 0)) == nil)
        precondition(RouteFollower(route: route([]), start: .beginning, location: nil) == nil)
        precondition(RouteFollower.nearestIndex(in: [], to: point(0)) == nil)
        precondition(RouteFollower.nearestIndex(in: geometry, to: .init(lat: 91, lon: 0)) == nil)
        precondition(RouteFollower.nearestIndex(in: geometry, to: .init(lat: 0, lon: 181)) == nil)
        precondition(RouteFollower.nearestIndex(in: [point(-1), point(1)], to: point(0)) == 0)
        precondition(RouteFollower.nearestIndex(in: [.init(lat: 0, lon: 179), .init(lat: 0, lon: -179.9)],
                                              to: .init(lat: 0, lon: 179.95)) == 1)

        let nearest = RouteFollower(route: value, start: .nearest, location: point(110))!
        precondition(nearest.targetIndex == 2, "Nearest means the next checkpoint after along-route projection, not nearest vertex")
        beginning.advance(at: point(0))
        precondition(beginning.targetIndex == 1)
        beginning.advance(at: point(95))
        precondition(beginning.targetIndex == 1 && beginning.arrivedIndices.contains(1),
                     "Entering a checkpoint bubble remembers arrival but does not skip its projected crossing")
        beginning.advance(at: point(130))
        precondition(beginning.targetIndex == 2, "Remembered arrival plus crossing may advance after leaving the bubble")
        beginning.advance(at: point(0))
        precondition(beginning.targetIndex == 2, "Navigation cannot go backwards")
        near(beginning.remainingDistanceMeters(from: point(0)), 200)
        beginning.advance(at: point(185))
        precondition(beginning.isComplete)
        near(beginning.remainingDistanceMeters(from: point(185)), 0)
        beginning.advance(at: point(200))
        precondition(beginning.targetIndex == geometry.count)

        var neverArrived = RouteFollower(route: route([point(0, checkpoint: false), point(100), point(300)]),
                                         start: .beginning, location: nil)!
        neverArrived.advance(at: point(130))
        precondition(neverArrived.targetIndex == 1, "Projected crossing alone cannot advance a never-arrived checkpoint")
        neverArrived.advance(at: point(300))
        precondition(neverArrived.isComplete, "Raw final arrival completes even with an earlier unvisited checkpoint")

        let dense = route([point(0), point(5), point(9), point(80)])
        var denseFollow = RouteFollower(route: dense, start: .beginning, location: nil)!
        denseFollow.advance(at: point(0))
        precondition(denseFollow.targetIndex == 1)
        denseFollow.advance(at: point(10))
        precondition(denseFollow.targetIndex == 3, "Dense checkpoints require crossing, not just overlapping bubbles")
        var duplicates = RouteFollower(route: route([point(0), point(0), point(80)]), start: .beginning, location: nil)!
        duplicates.advance(at: point(0))
        precondition(duplicates.targetIndex == 2)
        var duplicateFinal = RouteFollower(route: route([point(0), point(0)]), start: .beginning, location: nil)!
        duplicateFinal.advance(at: point(0))
        precondition(duplicateFinal.isComplete)

        let controls = route([point(0, checkpoint: false), point(100, checkpoint: false), point(200, checkpoint: false)])
        var controlFollow = RouteFollower(route: controls, start: .beginning, location: nil)!
        precondition(controlFollow.targetIndex == 2 && controlFollow.points.count == 3)
        controlFollow.advance(at: point(100))
        precondition(controlFollow.targetIndex == 2)
        controlFollow.advance(at: point(200))
        precondition(controlFollow.isComplete)
        let mixed = route([point(0, checkpoint: false), point(100), point(200, checkpoint: false)])
        precondition(RouteFollower(route: mixed, start: .beginning, location: nil)?.targetIndex == 1)
        precondition(RouteFollower(route: mixed, targetIndex: 0) == nil, "Control-only vertices are not objectives")
        near(RouteFollower(route: mixed, start: .beginning, location: nil)?.remainingDistanceMeters(from: point(0)), 200)
        let loop = route([point(0), point(100), point(0)])
        precondition(RouteFollower(route: loop, start: .nearest, location: point(50))?.targetIndex == 1,
                     "Equal-distance projections choose the first segment")
        let dateLine = route([.init(lat: 0, lon: 179.9), .init(lat: 0, lon: -179.9)])
        near(RouteFollower.projectedDistance(in: dateLine.points, to: .init(lat: 0, lon: 180)), 11_119.49266)

        for (method, radius) in [("Walking", 10.0), ("Swimming", 10), ("Driving", 20),
                                 ("Watercraft", 100), ("Flying", 1_000), ("Unknown", 10)] {
            let methodRoute = route([point(0), point(10_000)], method: method)
            var follower = RouteFollower(route: methodRoute, targetIndex: 1)!
            precondition(follower.arrivalRadiusMeters == radius)
            follower.advance(at: point(10_000 - radius - 0.01))
            precondition(!follower.isComplete, "\(method) must not arrive outside its radius")
            follower.advance(at: point(10_000 - radius + 0.01))
            precondition(follower.isComplete, "\(method) must arrive inside its radius")
        }
        let accuracyRoute = route([point(0), point(200)], method: "Walking")
        var withAccuracy = RouteFollower(route: accuracyRoute, targetIndex: 1)!
        withAccuracy.advance(at: point(180), accuracyMeters: 10.1)
        precondition(withAccuracy.isComplete, "GNSS CE expands method arrival radius")
        for invalid in [-1.0, .nan, .infinity] {
            var follower = RouteFollower(route: accuracyRoute, targetIndex: 1)!
            follower.advance(at: point(180), accuracyMeters: invalid)
            precondition(!follower.isComplete, "Invalid CE must contribute zero")
        }
        var largeCE = RouteFollower(route: accuracyRoute, targetIndex: 1)!
        largeCE.advance(at: point(0), accuracyMeters: 1_000_000)
        precondition(largeCE.isComplete, "Finite CE is not silently clamped")
        precondition(RouteFollower(route: value, targetIndex: -1) == nil)
        precondition(RouteFollower(route: value, targetIndex: 4) == nil)
        precondition(RouteFollower(route: value, targetIndex: value.points.count)?.isComplete == true)
        print("PASS: checkpoint/control objectives, projected nearest/crossing, remembered arrival, final override, method radius + CE, dense/loop/date-line geometry")
    }
}
