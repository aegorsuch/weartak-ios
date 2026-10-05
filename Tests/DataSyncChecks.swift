import Foundation

@main
struct DataSyncChecks {
    static func main() throws {
        let list = try TAKMissionAPI.parseList(Data("""
        {"version":"3","type":"Mission","data":[
          {"name":"Zulu","tool":"public","uids":[{"data":"a"},{"data":"b"}],"description":"  Main op  "},
          {"name":"alpha","passwordProtected":true},
          {"name":"checklist","tool":"ExCheck"},
          {"name":"Zulu","tool":"public"},
          {"name":"","tool":"public"},
          {"name":"bad\\u0007name"}
        ]}
        """.utf8))
        precondition(list.map(\.name) == ["alpha", "Zulu"], "\(list.map(\.name))")
        precondition(list[0].passwordProtected && list[0].itemCount == nil)
        precondition(list[1].itemCount == 2 && list[1].description == "Main op" && !list[1].subscribed)
        let empty = try TAKMissionAPI.parseList(Data(#"{"version":"1","type":"Mission","data":[]}"#.utf8))
        precondition(empty.isEmpty)
        do {
            _ = try TAKMissionAPI.parseList(Data("<html/>".utf8))
            fatalError("Non-JSON mission list accepted")
        } catch TAKMissionAPI.Failure.invalidResponse {}
        let many = (0..<60).map { #"{"name":"m\#($0)"}"# }.joined(separator: ",")
        let bounded = try TAKMissionAPI.parseList(Data(#"{"data":[\#(many)]}"#.utf8))
        precondition(bounded.count == TAKMissionAPI.maximumMissions)
        print("PASS: Data Sync mission list filtering, ordering and bounds")

        precondition(TAKMissionAPI.path("Op North/../x?y#z", "/cot") == "/missions/Op%20North%2F..%2Fx%3Fy%23z/cot")
        precondition(TAKMissionAPI.path("simple-name_1.v2~", "/subscription") == "/missions/simple-name_1.v2~/subscription")
        precondition(TAKMissionAPI.path("") == nil && TAKMissionAPI.path(String(repeating: "x", count: 129)) == nil)
        print("PASS: mission names are encoded as a single path segment")

        let cot = Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <events>
          <event version="2.0" uid="p1" type="a-h-G" time="2026-01-01T00:00:00Z" start="2026-01-01T00:00:00Z" stale="2026-01-02T00:00:00Z" how="h-g-i-g-o">
            <point lat="38.5" lon="-77.1" hae="0" ce="9" le="9"/><detail><contact callsign="Hostile 1"/></detail>
          </event>
          <event version="2.0" uid="p2" type="b-m-p-s-m" time="2026-01-01T00:00:00Z" start="2026-01-01T00:00:00Z" stale="2026-01-01T00:01:00.123Z" how="h-e">
            <point lat="38.6" lon="-77.2" hae="0" ce="9" le="9"/><detail><link uid="x"><point lat="1" lon="1"/></link></detail>
          </event>
          <event uid="p1" type="a-h-G"><point lat="1" lon="1"/></event>
          <event uid="chat" type="b-t-f"><point lat="1" lon="1"/></event>
          <event uid="del" type="t-x-d-d"><point lat="1" lon="1"/></event>
          <event uid="bad" type="a-f-G"><point lat="91" lon="1"/></event>
          <event uid="nopoint" type="a-f-G"><detail/></event>
        </events>
        """.utf8)
        let items = TAKMissionAPI.parseItems(cot)
        precondition(items.map(\.uid) == ["p1", "p2"], "\(items)")
        precondition(items[0].callsign == "Hostile 1" && items[0].lat == 38.5 && items[0].lon == -77.1 && items[0].type == "a-h-G")
        precondition(items[1].callsign == nil && items[1].lat == 38.6, "Nested link points must not replace the event point")
        precondition(items[1].stale != nil, "Stale items stay in the mission; stale time is kept")
        precondition(TAKMissionAPI.parseItems(cot, limit: 1).map(\.uid) == ["p1"])
        let bare = Data(#"<?xml version="1.0"?><event uid="b1" type="a-n-G"><point lat="2" lon="3"/></event><?xml version="1.0"?><event uid="b2" type="a-n-G"><point lat="4" lon="5"/></event>"#.utf8)
        precondition(TAKMissionAPI.parseItems(bare).map(\.uid) == ["b1", "b2"])
        precondition(TAKMissionAPI.parseItems(Data(#"<!DOCTYPE x [<!ENTITY e "x">]><events/>"#.utf8)).isEmpty)
        precondition(TAKMissionAPI.parseItems(Data("<events/>".utf8)).isEmpty)
        print("PASS: mission CoT parsing, filtering, dedupe and limits")

        let serverID = UUID()
        let update = BridgeWire.Message(kind: .missionUpdate, serverID: serverID, clientUID: "watch-uid",
                                        missionName: "Op North", missionSubscribe: true)
        let decoded = try BridgeWire.Message.decode(update.encoded())
        precondition(decoded.missionName == "Op North" && decoded.missionSubscribe == true && decoded.serverID == serverID)
        for invalid in [
            BridgeWire.Message(kind: .missionUpdate, serverID: serverID, missionName: "x"),
            BridgeWire.Message(kind: .missionUpdate, missionName: "x", missionSubscribe: true),
            BridgeWire.Message(kind: .missionUpdate, serverID: serverID, missionName: "", missionSubscribe: false)
        ] {
            do {
                _ = try BridgeWire.Message.decode(invalid.encoded())
                fatalError("Invalid mission update accepted")
            } catch BridgeWire.Failure.invalidMission {}
        }
        var remove = BridgeWire.Message(kind: .missionUpdate, serverID: serverID, clientUID: "watch-uid", missionName: "Op North")
        remove.missionRemoveUID = "item-1"
        precondition(try BridgeWire.Message.decode(remove.encoded()).missionRemoveUID == "item-1")
        remove.missionSubscribe = true
        do {
            _ = try BridgeWire.Message.decode(remove.encoded())
            fatalError("A mission update must not both subscribe and remove")
        } catch BridgeWire.Failure.invalidMission {}
        remove.missionSubscribe = nil
        remove.missionRemoveUID = ""
        do {
            _ = try BridgeWire.Message.decode(remove.encoded())
            fatalError("An empty removal UID must be rejected")
        } catch BridgeWire.Failure.invalidMission {}
        var server = TAKMissionServer(id: serverID, name: "tak.example:8089")
        precondition(!server.isLoaded && server.state == TAKMissionServer.selectState)
        server.state = TAKMissionServer.emptyState
        precondition(server.isLoaded)
        server.state = TAKMissionServer.readyState
        server.missions = [TAKMission(name: "Op North", subscribed: true,
            items: (0..<TAKMissionAPI.maximumItemsTotal).map {
                TAKMissionItem(uid: "uid-\($0)-\(UUID().uuidString)", type: "a-h-G", callsign: "Item \($0)",
                               lat: 38.5, lon: -77.1, stale: Date())
            })]
        var reply = BridgeWire.Message(kind: .missions, sessionID: UUID())
        reply.missionServers = [server]
        let encoded = try reply.encoded()
        let roundTrip = try BridgeWire.Message.decode(encoded)
        precondition(roundTrip.missionServers?.first?.missions.first?.items?.count == TAKMissionAPI.maximumItemsTotal,
                     "The full item budget must fit one watch message")
        print("PASS: Data Sync bridge messages validate and the item budget fits (\(encoded.count) bytes)")

        func role(_ json: String) -> Bool? { TAKMissionAPI.parseCanEdit(Data(json.utf8)) }
        precondition(role(#"{"data":{"role":{"type":"MISSION_SUBSCRIBER","permissions":["MISSION_READ","MISSION_WRITE"]}}}"#) == true)
        precondition(role(#"{"data":{"role":{"type":"MISSION_READONLY_SUBSCRIBER","permissions":["MISSION_READ"]}}}"#) == false)
        precondition(role(#"{"data":{"role":{"type":"MISSION_OWNER"}}}"#) == true)
        precondition(role(#"{"data":{"role":{"type":"MISSION_READONLY_SUBSCRIBER"}}}"#) == false)
        precondition(role(#"{"data":{}}"#) == nil && role("<html/>") == nil)
        precondition(TAKMissionAPI.type("a-h-G-U-C", affiliation: "f") == "a-f-G-U-C")
        precondition(TAKMissionAPI.type("b-m-p-s-m", affiliation: "n") == "a-n-G")
        precondition(TAKMissionAPI.removalMessage("Data Sync API: HTTP 403.") == "Your mission role doesn't allow deleting items.")
        let edited = TAKMissionItem(uid: "u\"1", type: "a-f-G", callsign: "A&B <1>", lat: 38.5, lon: -77.1,
                                    remark: "Gate 'north'")
        let event = TAKMissionAPI.itemEvent(edited, mission: "Op \"North\"", now: Date(timeIntervalSince1970: 0))
        precondition(event.contains(#"uid="u&quot;1""#) && event.contains(#"callsign="A&amp;B &lt;1&gt;""#))
        precondition(event.contains("<remarks>Gate &apos;north&apos;</remarks>"))
        precondition(event.contains(#"<marti><dest mission="Op &quot;North&quot;"/></marti>"#))
        let reparsed = TAKMissionAPI.parseItems(Data(event.utf8))
        precondition(reparsed.count == 1 && reparsed[0].callsign == "A&B <1>" && reparsed[0].remark == "Gate 'north'"
                     && reparsed[0].lat == 38.5 && reparsed[0].type == "a-f-G")
        print("PASS: Data Sync item edits, removal and mission role permissions")
        print("All Data Sync checks passed")
    }
}
