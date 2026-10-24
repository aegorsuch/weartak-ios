import SwiftUI

struct WatchRouteListView: View {
    @ObservedObject var model: WatchSessionModel

    var body: some View {
        List {
            if let error = model.routeError {
                Text(error).foregroundStyle(.red)
            }
            if model.watchRoutes.routes.isEmpty {
                Text("No routes on this watch. Send a route Data Package from ATAK through your configured TAK server.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.watchRoutes.routes) { route in
                NavigationLink {
                    WatchRouteDetailView(model: model, key: WatchRoutes.key(route))
                } label: {
                    VStack(alignment: .leading) {
                        Text(route.name)
                        Text("\(route.namedPoints.count) named points · \(route.points.count) total")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button("Refresh Routes") {
                Task { await model.companionClient.refreshRoutes() }
            }
        }
        .navigationTitle("Routes")
    }
}

struct WatchRouteDetailView: View {
    @ObservedObject var model: WatchSessionModel
    @AppStorage(DistanceUnits.storageKey) private var distanceUnits = DistanceUnits.metric
    let key: String
    @State private var confirmRemoval = false
    @Environment(\.dismiss) private var dismiss

    private var route: GarminRoute? {
        model.watchRoutes.routes.first { WatchRoutes.key($0) == key }
    }

    var body: some View {
        List {
            if let route {
                Section {
                    Text(route.name).font(.headline)
                    Text("Arrival radius: \(distanceUnits.radius(RouteFollower.arrivalRadiusMeters(method: route.method))))")
                    Text("\(route.namedPoints.count) named points · \(route.points.count) total")
                        .foregroundStyle(.secondary)
                    if let serverID = UUID(uuidString: route.serverId) {
                        LabeledContent("Source", value: model.chatRouteTitle(.companion(serverID)))
                    }
                    if let mission = route.missionName { Text(mission).font(.caption) }
                }
                Section {
                    WatchRouteFollowControls(model: model, route: route)
                }
                if let message = model.routeCompletionMessage {
                    Text(message).foregroundStyle(.green)
                }
                Section("Select Point") {
                    if route.namedPoints.isEmpty {
                        Text("This route has no named points. Its full path is still shown on the map.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(route.namedPoints, id: \.index) { namedPoint in
                            let index = namedPoint.index
                            let point = namedPoint.point
                            let active = model.routeFollow == nil && model.routeBloodhoundKey == key && model.routeBloodhoundIndex == index
                            Button {
                                model.toggleRouteBloodhound(route, index: index)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(namedPoint.name)
                                    Text(active ? String(localized: "Stop Bloodhound", table: "WatchMain")
                                         : String(localized: "Bloodhound to Point"))
                                        .font(.caption)
                                    Text(String(format: "%.5f, %.5f", point.lat, point.lon))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if let error = model.routeError { Text(error).foregroundStyle(.red) }
                Button("Remove from This Watch", role: .destructive) { confirmRemoval = true }
            } else {
                Text("This route is no longer on this watch.")
            }
        }
        .navigationTitle("Route")
        .onAppear { model.requestLocation() }
        .confirmationDialog("Remove this route from this watch?", isPresented: $confirmRemoval, titleVisibility: .visible) {
            Button("Remove from This Watch", role: .destructive) {
                if let route {
                    model.removeRouteFromWatch(route)
                    if self.route == nil { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The route stays on the TAK server and other devices. Bloodhound to this route will stop. A later resend, Data Sync or refresh may restore it.")
        }
    }
}

struct WatchRouteProgressView: View {
    @ObservedObject var model: WatchSessionModel
    @AppStorage(DistanceUnits.storageKey) private var distanceUnits = DistanceUnits.metric

    var body: some View {
        if let follow = model.routeFollow, !follow.isComplete {
            VStack(alignment: .leading, spacing: 4) {
                if let route = model.watchRoutes.routes.first(where: { $0.id == follow.routeID }) {
                    Text(route.name).font(.headline)
                }
                Text("Point \(follow.targetIndex + 1) of \(follow.points.count)")
                    .font(.caption)
                if let location = model.routeLocation,
                   let remaining = follow.remainingDistanceMeters(from: location) {
                    Text("Remaining: \(distanceUnits.distance(remaining))").font(.caption2)
                } else {
                    Text("Remaining distance unavailable").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct WatchRouteFollowControls: View {
    @ObservedObject var model: WatchSessionModel
    let route: GarminRoute

    var body: some View {
        if model.routeFollow?.routeID == route.id {
            WatchRouteProgressView(model: model)
            Button("Stop route", role: .destructive) { model.stopRouteFollowing() }
        } else {
            Button("Start nearest") { model.startRouteFollowing(route, start: .nearest) }
                .disabled(model.routeLocation == nil)
            if model.routeLocation == nil {
                Text("Start nearest requires a current location. Enable location and try again.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button("Start from beginning") { model.startRouteFollowing(route, start: .beginning) }
        }
    }
}
