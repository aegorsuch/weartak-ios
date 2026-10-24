import Foundation

struct WatchRoutes: Codable {
    private(set) var routes: [GarminRoute] = []

    static func key(_ route: GarminRoute) -> String { route.id }

    mutating func replace(_ values: [GarminRoute]) throws {
        var store = GarminRouteStore()
        for route in values { try store.upsert(route) }
        guard store.routes.count == values.count else { throw GarminRoute.Failure.invalid }
        routes = store.routes
    }

    mutating func receive(_ events: [GarminRouteCoT.Event], serverID: String) throws {
        var store = GarminRouteStore()
        for route in routes { try store.upsert(route) }
        for event in events {
            switch event {
            case .route(let route):
                try store.upsert(route)
            case .remove(let uid): store.remove(serverId: serverID, uid: uid)
            }
        }
        routes = store.routes
    }

    mutating func remove(_ route: GarminRoute) {
        routes.removeAll { $0.uid == route.uid }
    }

    mutating func removeAll() {
        routes.removeAll()
    }
}
