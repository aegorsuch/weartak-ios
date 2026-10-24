import SwiftUI

struct PhoneRouteListView: View {
    @ObservedObject var bridge: PhoneBridgeModel

    var body: some View {
        List {
            if let error = bridge.routeNavigationError {
                Text(error).foregroundStyle(.red)
            }
            if let state = bridge.routeNavigationState {
                Section {
                    Text(state.route.name).font(.headline)
                    if state.phase == .active {
                        Text("Point \(state.targetIndex + 1) of \(state.route.points.count)")
                        if let location = bridge.routeLocation,
                           let follower = RouteFollower(route: state.route, targetIndex: state.targetIndex),
                           let remaining = follower.remainingDistanceMeters(from: location) {
                            Text("Remaining: \(Int(remaining.rounded())) m")
                        } else {
                            Text("Remaining distance unavailable").foregroundStyle(.secondary)
                        }
                        Button("Stop route", role: .destructive) { bridge.stopRouteNavigation() }
                    } else {
                        Text(state.phase == .completed ? String(localized: "Route complete") : String(localized: "Route stopped"))
                    }
                } header: { Text("Navigation") }
            }
            Section {
                if bridge.navigationRoutes.isEmpty {
                    Text("No routes. Send a route Data Package from ATAK through your configured TAK server.")
                        .foregroundStyle(.secondary)
                }
                ForEach(bridge.navigationRoutes) { route in
                    NavigationLink {
                        PhoneRouteDetailView(bridge: bridge, route: route)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(route.name)
                            Text("\(route.namedPoints.count) named points · \(route.points.count) total")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: { Text("Routes") }
            Text("Start, progress, stop and completion are shared with your paired Apple Watch. Changes made offline sync when the devices reconnect.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .navigationTitle("Routes")
        .onAppear { bridge.requestRouteLocation() }
    }
}

private struct PhoneRouteDetailView: View {
    @ObservedObject var bridge: PhoneBridgeModel
    let route: GarminRoute

    var body: some View {
        List {
            Section {
                Text(route.name).font(.headline)
                Text("Arrival radius: \(Int(RouteFollower.arrivalRadiusMeters(method: route.method))) m")
            }
            Section {
                if let state = bridge.routeNavigationState, state.phase == .active, state.route.id == route.id {
                    Text("Point \(state.targetIndex + 1) of \(state.route.points.count)")
                    Button("Stop route", role: .destructive) { bridge.stopRouteNavigation() }
                } else {
                    TimelineView(.periodic(from: .now, by: 10)) { _ in
                        Button("Start nearest") { bridge.startRouteNavigation(route, start: .nearest) }
                            .disabled(bridge.routeLocation == nil)
                    }
                    if bridge.routeLocation == nil {
                        Text("Start nearest requires a current location. Enable location and try again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Start from beginning") { bridge.startRouteNavigation(route, start: .beginning) }
                }
            }
            if let error = bridge.routeNavigationError { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Route")
        .onAppear { bridge.requestRouteLocation() }
    }
}
