import Foundation

@main
struct GarminRouteChecks {
    static func main() throws {
        let server = UUID().uuidString
        let otherServer = UUID().uuidString
        func route(_ uid: String = "route", count: Int = 2, serverId: String? = nil,
                   mission: String? = nil) -> GarminRoute {
            GarminRoute(serverId: serverId ?? server, uid: uid, name: "Test route",
                        missionName: mission, points: (0..<count).map {
                            GarminRoute.Point(lat: 38 + Double($0) / 1000, lon: -77, name: "Point \($0)")
                        })
        }
        func rejects(line: UInt = #line, _ body: () throws -> Void) {
            do { try body(); fatalError("Expected route rejection at line \(line)") }
            catch is GarminRoute.Failure {}
            catch { fatalError("Unexpected error: \(error)") }
        }
        _ = try route(count: 64).validated()
        rejects { _ = try route(count: 1).validated() }
        rejects { _ = try route(count: 65).validated() }
        var invalid = route()
        invalid.name = String(repeating: "é", count: 33)
        rejects { _ = try invalid.validated() }
        invalid = route()
        invalid.name = "line\nbreak"
        rejects { _ = try invalid.validated() }
        invalid = route()
        invalid.senderUid = String(repeating: "x", count: 129)
        rejects { _ = try invalid.validated() }
        invalid = route()
        invalid.missionName = String(repeating: "é", count: 65)
        rejects { _ = try invalid.validated() }
        rejects { _ = try route(serverId: String(repeating: "x", count: 65)).validated() }
        rejects { _ = try route(String(repeating: "é", count: 65)).validated() }
        rejects {
            _ = try GarminRoute(serverId: server, uid: "bad", name: "Bad",
                points: [.init(lat: 0, lon: 0, name: String(repeating: "é", count: 33)),
                         .init(lat: 1, lon: 1)]).validated()
        }
        _ = try GarminRoute(serverId: server, uid: "edges", name: "Edges",
                            points: [.init(lat: -90, lon: -180), .init(lat: 90, lon: 180)]).validated()
        rejects {
            _ = try GarminRoute(serverId: server, uid: "bad", name: "Bad",
                                points: [.init(lat: .nan, lon: 0), .init(lat: 0, lon: 0)]).validated()
        }
        rejects {
            _ = try GarminRoute(serverId: server, uid: "bad", name: "Bad",
                                points: [.init(lat: 0, lon: 181), .init(lat: 0, lon: 0)]).validated()
        }
        let huge = GarminRoute(serverId: server, uid: "large", name: "Large",
            points: (0..<64).map { .init(lat: Double($0), lon: 120, name: String(repeating: "x", count: 64)) })
        rejects { _ = try huge.validated() }
        let json = try JSONSerialization.data(withJSONObject: ["msgType": "route", "payload": route().payload])
        precondition(json.count <= 6_000)
        let payload = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        precondition(payload["msgType"] as? String == "route")
        precondition((payload["payload"] as! [String: Any])["routeVersion"] as? Int == 1)
        precondition(route().removalPayload["serverId"] as? String == server)

        let xml = """
        <?xml version="1.0"?><events><event uid="route&amp;1" type="b-m-r" stale="2000-01-01T00:00:00Z">
        <point lat="1" lon="2"/><detail><contact callsign="Route &amp; One"/>
        <link uid="sender" relation="p-p"/>
        <link uid="a" relation="c" point="38.1,-77.2,10" callsign="Alpha"/>
        <link uid="b" relation="c" point="38.2,-77.3" callsign="Bravo"/>
        </detail></event></events>
        """
        let parsed = try GarminRouteCoT.parse(Data(xml.utf8), serverId: server, missionName: "Mission")
        guard case .route(let normalized) = parsed.first else { fatalError("Missing route") }
        precondition(normalized.uid == "route&1" && normalized.name == "Route & One")
        precondition(normalized.missionName == "Mission" && normalized.senderUid == "sender")
        precondition(normalized.points.count == 2 && normalized.points[0].name == "Alpha")
        precondition(normalized.points[0].lat == 38.1 && normalized.points[1].lon == -77.3)
        let withParentPosition = try GarminRouteCoT.parse(
            Data(xml.replacingOccurrences(of: "uid=\"sender\" relation=\"p-p\"",
                                          with: "uid=\"sender\" relation=\"p-p\" point=\"0,0\"").utf8),
            serverId: server)
        guard case .route(let withoutParentPoint) = withParentPosition.first else { fatalError("Missing route") }
        precondition(withoutParentPoint.points.count == 2)
        let pointEvents = try GarminRouteCoT.parse(
            Data("<event uid=\"point\" type=\"a-f-G\"><point lat=\"0\" lon=\"0\"/></event>".utf8), serverId: server)
        precondition(pointEvents.isEmpty)
        let deletion = "<event uid=\"delete\" type=\"t-x-d-d\"><detail><link uid=\"route&amp;1\"/></detail></event>"
        guard case .remove(let removed) = try GarminRouteCoT.parse(Data(deletion.utf8), serverId: server).first else {
            fatalError("Missing removal")
        }
        precondition(removed == "route&1")
        rejects { _ = try GarminRouteCoT.parse(Data(xml.replacingOccurrences(of: "38.1,-77.2,10", with: "NaN,0").utf8), serverId: server) }
        rejects { _ = try GarminRouteCoT.parse(Data(xml.replacingOccurrences(of: "point=\"38.1,-77.2,10\"", with: "").utf8), serverId: server) }
        rejects { _ = try GarminRouteCoT.parse(Data((xml + "<broken>").utf8), serverId: server) }
        rejects {
            _ = try GarminRouteCoT.parse(Data("<!DOCTYPE r [<!ENTITY x 'bad'>]><event/>".utf8), serverId: server)
        }
        let tooMany = "<event uid=\"many\" type=\"b-m-r\"><detail>" +
            String(repeating: "<link relation=\"c\" point=\"0,0\"/>", count: 65) + "</detail></event>"
        rejects { _ = try GarminRouteCoT.parse(Data(tooMany.utf8), serverId: server) }

        var store = GarminRouteStore()
        try store.upsert(route("one", count: 64))
        try store.upsert(route("two", count: 64))
        rejects { try store.upsert(route("three")) }
        precondition(store.routes.count == 2 && store.routes[0].points.count == 64)
        try store.upsert(route("one", count: 2))
        try store.upsert(route("three"))
        precondition(store.routes.count == 3)
        store = GarminRouteStore()
        for i in 0..<8 { try store.upsert(route("route-\(i)")) }
        rejects { try store.upsert(route("ninth")) }
        try store.upsert(route("route-0"))
        precondition(store.routes.count == 8)
        store.remove(serverId: otherServer, uid: "route-0")
        precondition(store.routes.count == 8)
        store.remove(serverId: server, uid: "route-0")
        precondition(store.routes.count == 7)

        store = GarminRouteStore()
        try store.upsert(route("shared", mission: "A"), mission: "A")
        try store.upsert(route("shared", mission: "B"), mission: "B")
        try store.upsert(route("shared", serverId: otherServer))
        try store.replaceMission(serverId: server, name: "A", routes: [])
        precondition(store.routes.count == 2)
        precondition(store.routes.first { $0.serverId == server }?.missionName == "B")
        store.retainMissions(serverId: server, names: [])
        precondition(store.routes.count == 1 && store.routes[0].serverId == otherServer)
        try store.upsert(route("both", mission: "A"), mission: "A")
        try store.upsert(route("both"))
        store.retainMissions(serverId: server, names: [])
        precondition(store.routes.contains { $0.uid == "both" && $0.missionName == nil })
        store.retainServers([server])
        precondition(store.routes.count == 1)
        let restored = try JSONDecoder().decode(GarminRouteStore.self, from: JSONEncoder().encode(store)).validated()
        precondition(restored.routes == store.routes)
        store.removeServer(server)
        precondition(store.routes.isEmpty)
        try store.upsert(route("mission-only", mission: "A"), mission: "A")
        store.removeMissionItem(serverId: server, name: "A", uid: "unrelated")
        precondition(store.routes.count == 1)
        store.removeMissionItem(serverId: server, name: "A", uid: "mission-only")
        precondition(store.routes.isEmpty)

        store = GarminRouteStore()
        try store.replaceMission(serverId: server, name: "A", routes: [route("old", mission: "A")])
        rejects {
            try store.replaceMission(serverId: server, name: "A",
                                     routes: [route("new1", count: 64, mission: "A"),
                                              route("new2", count: 64, mission: "A"),
                                              route("overflow", mission: "A")])
        }
        precondition(store.routes.count == 1 && store.routes[0].uid == "old")
        try store.replaceMission(serverId: server, name: "A", routes: [])
        precondition(store.routes.isEmpty)
        print("Garmin route checks passed")
    }
}
