import Foundation

@main
struct BloodhoundPickerChecks {
    static func main() throws {
        precondition(WatchPinTitle.trimmingTrailingWhitespace("Pin \t\r\n") == "Pin")
        precondition(WatchPinTitle.trimmingTrailingWhitespace("  Pin \u{2003}\u{00A0}") == "  Pin")
        precondition(WatchPinTitle.trimmingTrailingWhitespace(" \t") == "")
        precondition(WatchPinTitle.trimmingTrailingWhitespace("Pin \u{1F9ED}") == "Pin \u{1F9ED}")
        for title in ["", "  Leading", "Inner  whitespace", "A&B <tag>", "MOPP 2", "e\u{301}"] {
            precondition(WatchPinTitle.trimmingTrailingWhitespace(title) == title)
            precondition(WatchPinTitle.trimmingTrailingWhitespace(title + "\t \r\n\u{2003}") == title)
        }
        let source = try String(contentsOfFile: "WearTAK Watch App/WatchSessionModel.swift", encoding: .utf8)
        let mapSource = try String(contentsOfFile: "WearTAK Watch App/ContentView.swift", encoding: .utf8)
        precondition(mapSource.contains("ForEach(sortedMapPointSelections(cluster.selections)"),
                     "Overlapping map items must be listed in sorted order")
        precondition(mapSource.contains("left.localizedStandardCompare(right)"),
                     "Map item sorting must follow localized alphabetical order")
        precondition(mapSource.contains("Text(\"Self-Location\", tableName: \"WatchMain\")") &&
                     mapSource.contains("String(format: \"%.5f\", coordinate.latitude)") &&
                     mapSource.contains("String(format: \"%.5f\", coordinate.longitude)"),
                     "The self popup must label its coordinates and retain five-decimal precision")
        precondition(mapSource.contains("return callSign.isEmpty ? String(localized: \"You\", table: \"WatchMain\") : \"\\(callSign) (you)\""),
                     "The visible self marker must identify the user by callsign")
        precondition(mapSource.contains("bounds: MapCameraBounds(minimumDistance: 11)"),
                     "Pinch zoom must be bounded at close range")
        let selectable = mapSource.components(separatedBy: "private func selectableMapPoints()")[1]
            .components(separatedBy: "private func mapPointTitle(")[0]
        precondition(selectable.contains("points.append((.selfMarker, location.coordinate))") &&
                     selectable.contains("model.markers.map { (.marker($0.id), $0.coordinate) }"),
                     "Self and dropped pins must both participate in overlap selection")
        precondition(mapSource.contains("hypot(candidate.1.x - anchorPoint.x, candidate.1.y - anchorPoint.y) <= 32"),
                     "Items under the self marker must enter the same overlap picker")
        let selfDetails = mapSource.components(separatedBy: "private struct SelfCoordinateView:")[1]
            .components(separatedBy: "private extension TeamColor")[0]
        precondition(!selfDetails.contains("Bloodhound"),
                     "The self-location popup must not offer Bloodhound")
        let contactDetails = mapSource.components(separatedBy: "private struct MapContactDetailView:")[1]
            .components(separatedBy: "private struct ContactChatView")[0]
        precondition(contactDetails.contains("model.toggleContactBloodhound(uid: uid)"),
                     "Contact map items must offer Bloodhound")
        let pointDetails = mapSource.components(separatedBy: "private struct IncomingPointDetailView:")[1]
            .components(separatedBy: "private extension TeamColor")[0]
        precondition(pointDetails.contains("model.toggleMapItemBloodhound(id: id)"),
                     "Incoming map items, including aircraft, must offer Bloodhound")
        precondition(mapSource.contains("model.toggleBloodhound(id: marker.id)"),
                     "Dropped pins must offer Bloodhound")
        let removal = source.components(separatedBy: "func removePickerTarget(")[1]
            .components(separatedBy: "func removeAllPickerTargets(")[0]
        precondition(removal.contains("case .marker(let id):\n            deleteMarker(id: id)"))
        precondition(removal.contains("case .point(let id): removeIncomingPoint(id)"))
        let clear = source.components(separatedBy: "func removeAllPickerTargets() {")[1]
            .components(separatedBy: "var routeLocation:")[0]
        precondition(clear.contains("for marker in markers { removePickerTarget(.marker(marker.id)) }"))
        precondition(clear.contains("removePickerTarget(.contact(contact.id))") &&
            clear.contains("removePickerTarget(.point(point.id))"))
        let delete = source.components(separatedBy: "func deleteMarker(id: UUID) {")[1]
            .components(separatedBy: "func clearAllPoints()")[0]
        precondition(delete.contains("markers.firstIndex(where: { $0.id == id })"))
        precondition(delete.range(of: "markers.firstIndex")!.lowerBound <
            delete.range(of: "storeOffline(")!.lowerBound)
        precondition(delete.contains("OfflineOperation(kind: .delete") && delete.contains("deleteMarkerXML(uid: id.uuidString)"))
        let creation = source.components(separatedBy: "func storeMarker(")[1]
            .components(separatedBy: "func updateMarker(")[0]
        precondition(creation.contains("let title = WatchPinTitle.trimmingTrailingWhitespace(title)"))
        let edit = source.components(separatedBy: "func updateMarker(")[1]
            .components(separatedBy: "func moveMarker(")[0]
        precondition(!edit.contains("trimmingTrailingWhitespace") && edit.contains("marker.remark = remark"))
        let client = try String(contentsOfFile: "WearTAK Watch App/SitxClient.swift", encoding: .utf8)
        let payload = client.components(separatedBy: "func deleteMarkerXML(uid: String) -> String {")[1]
            .components(separatedBy: "func sendEmergencyAlert(")[0]
        precondition(payload.contains("relation=\\\"none\\\" type=\\\"none\\\"") &&
            payload.contains("<__forcedelete/>") && payload.contains("SitxCoT.escape(uid)"))
        precondition(payload.contains("type: \"t-x-d-d\"") && payload.contains("uid: uid + \"-delete\""))
        print("PASS: new-title trailing whitespace only; own-marker deletion guard precedes queue; received items remain local-only")
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
                             "Delete must select removal without toggling navigation; only locally created pins request remote deletion")
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
