import Foundation

@main
struct BloodhoundPickerChecks {
    static func main() {
        typealias Target = BloodhoundPicker.Target
        let markerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let targets: [Target] = [.route("server\nroute"), .route("other\nroute"),
            .marker(markerID), .contact("same-id"), .point("same-id")]
        precondition(Set(targets).count == targets.count, "Target kinds and route sources cannot collide")
        precondition(BloodhoundPicker.indicator(for: nil) == nil, "No target must hide the compass icon")
        for target in targets {
            if case .route = target {
                precondition(BloodhoundPicker.indicator(for: target) == .route)
            } else {
                precondition(BloodhoundPicker.indicator(for: target) == nil,
                             "The active compass already gives direction; hide the redundant Bloodhound icon")
            }
        }
        let activeTargets: [Target?] = [nil] + targets.map { Optional($0) }
        for target in targets {
            for active in activeTargets {
                precondition(BloodhoundPicker.command(for: .showOnMap, target: target, active: active) == .showOnMap(target),
                             "Map preview must never start or stop navigation, even for the active row")
                precondition(BloodhoundPicker.command(for: .remove, target: target, active: active) == .remove(target),
                             "Delete must select local removal, never toggle navigation or transmit server deletion")
                let expected: BloodhoundPicker.Command
                if active == target { expected = .stop }
                else if case .route(let id) = target { expected = .chooseRoute(id) }
                else { expected = .start(target) }
                precondition(BloodhoundPicker.command(for: .bloodhound, target: target, active: active) == expected)
            }
        }
        // No selected start mode means no new follower; nearest without GPS is never beginning.
        let route = GarminRoute(serverId: "server", uid: "route", name: "Test route",
            points: [.init(lat: 38, lon: -77), .init(lat: 38.01, lon: -77.02)])
        precondition(RouteFollower(route: route, start: .nearest, location: nil) == nil)
        precondition(RouteFollower(route: route, start: .beginning, location: nil)?.targetIndex == 0)
        precondition(RouteFollower(route: route, start: .nearest, location: route.points[1])?.targetIndex == 1)

        func near(_ actual: Double, _ expected: Double) {
            precondition(abs(actual - expected) < 0.000001, "Unexpected map bounds: \(actual), expected \(expected)")
        }
        precondition(BloodhoundMapBounds(points: []) == nil)
        precondition(BloodhoundMapBounds(points: [.init(lat: .nan, lon: 0)]) == nil)
        precondition(BloodhoundMapBounds(points: [.init(lat: 0, lon: 181)]) == nil)
        precondition(BloodhoundMapBounds(points: [.init(lat: 91, lon: 0)]) == nil)
        let point = BloodhoundMapBounds(points: [route.points[0]])!
        near(point.latitude, 38); near(point.longitude, -77)
        near(point.latitudeDelta, 0.01); near(point.longitudeDelta, 0.01)
        let fit = BloodhoundMapBounds(points: route.points)!
        near(fit.latitude, 38.005); near(fit.longitude, -77.01)
        near(fit.latitudeDelta, 0.014); near(fit.longitudeDelta, 0.028)
        let wrapped = BloodhoundMapBounds(points: [.init(lat: 1, lon: 179.9), .init(lat: 2, lon: -179.9)])!
        near(abs(wrapped.longitude), 180); near(wrapped.longitudeDelta, 0.28)
        near(wrapped.latitude, 1.5); near(wrapped.latitudeDelta, 1.4)
        let duplicate = BloodhoundMapBounds(points: [route.points[0], route.points[0]])!
        near(duplicate.longitudeDelta, 0.01)
        print("PASS: all picker actions/active identities, map-preview isolation, route start policy and fitted map bounds")
    }
}
