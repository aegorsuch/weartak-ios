import Foundation

@main
struct BridgeProtocolChecks {
    static func main() throws {
        let groups = try TAKChannelGroups.parse(Data("{\"data\":[{\"name\":\"Operations\",\"bitpos\":7,\"direction\":\"IN\",\"active\":true,\"preserve\":\"value\"},{\"name\":\"Operations\",\"bitpos\":7,\"direction\":\"OUT\",\"active\":true},{\"name\":\"Other\",\"bitpos\":8,\"active\":false}]}".utf8))
        precondition(groups.channels.count == 2)
        let changed = try groups.changing(bitPosition: 7, active: false)
        precondition(changed.payload[0]["active"] as? Bool == false && changed.payload[1]["active"] as? Bool == false)
        precondition(changed.payload[0]["preserve"] as? String == "value")
        precondition(changed.payload[2]["active"] as? Bool == false)
        let encodedGroups = try JSONSerialization.jsonObject(with: changed.encodedPayload()) as? [[String: Any]]
        precondition(encodedGroups?.count == 3)
        let supported = try TAKChannelGroups.support(Data("{\"data\":true}".utf8))
        precondition(supported)
        do {
            _ = try groups.changing(bitPosition: 999, active: true)
            fatalError("Unknown channel accepted")
        } catch TAKChannelGroups.ChannelError.unknownChannel {}
        print("PASS: directional channel pairing, full-payload updates and support parsing")
        let channelServerID = UUID()
        let bridgeSessionID = UUID()
        let selection = BridgeWire.Message(kind: .channelUpdate, serverID: channelServerID,
            channelBitPosition: 7, channelActive: false, clientUID: "watch-uid")
        let decodedSelection = try BridgeWire.Message.decode(selection.encoded())
        precondition(decodedSelection.id == selection.id && decodedSelection.serverID == channelServerID)
        precondition(decodedSelection.channelBitPosition == 7 && decodedSelection.channelActive == false && decodedSelection.clientUID == "watch-uid")
        let channelServer = TAKChannelServer(id: channelServerID, name: "tak.example:8089", channels: changed.channels, state: "Ready")
        let snapshot = BridgeWire.Message(kind: .channels, id: selection.id, channelServers: [channelServer],
            sourceServerID: channelServerID, sourceGeneration: 2, sessionID: bridgeSessionID)
        let decodedSnapshot = try BridgeWire.Message.decode(snapshot.encoded())
        precondition(decodedSnapshot.channelServers == [channelServer] && decodedSnapshot.id == selection.id)
        precondition(decodedSnapshot.sourceServerID == channelServerID && decodedSnapshot.sourceGeneration == 2 && decodedSnapshot.sessionID == bridgeSessionID)
        let locationStatus = BridgeWire.Message(kind: .status, phoneLocationEnabled: true)
        let decodedLocation = try BridgeWire.Message.decode(locationStatus.encoded())
        precondition(decodedLocation.phoneLocationEnabled == true)
        let legacyStatus = try BridgeWire.Message.decode(BridgeWire.Message(kind: .status).encoded())
        precondition(legacyStatus.phoneLocationEnabled == nil)
        precondition(legacyStatus.sitxSettings == nil)
        let phoneSitx = SitxSettingsSnapshot(enabled: true, host: "https://team.sitx.io",
            groupName: "Operations", status: "Connected")
        let mirroredSitx = try BridgeWire.Message.decode(
            BridgeWire.Message(kind: .status, sitxSettings: phoneSitx).encoded())
        precondition(mirroredSitx.sitxSettings == phoneSitx && phoneSitx.isPresent)
        let offSitx = SitxSettingsSnapshot(enabled: false, host: phoneSitx.host,
            groupName: phoneSitx.groupName, status: "Off")
        let contextSitx = try JSONDecoder().decode(SitxSettingsSnapshot.self, from: JSONEncoder().encode(offSitx))
        precondition(contextSitx == offSitx && contextSitx.isPresent)
        let removedSitx = SitxSettingsSnapshot(enabled: false, host: "", status: "Not connected")
        precondition(!removedSitx.isPresent)
        let removedReply = try BridgeWire.Message.decode(
            BridgeWire.Message(kind: .status, sitxSettings: removedSitx).encoded())
        precondition(removedReply.sitxSettings == removedSitx)
        let removeSitx = SitxRelayConfig(enabled: false, host: "", flowTag: "", removeConnection: true)
        let removal = try BridgeWire.Message.decode(
            BridgeWire.Message(kind: .sitxConfig, sitxConfig: removeSitx).encoded())
        precondition(removal.sitxConfig?.removeConnection == true && removal.sitxConfig?.refreshToken == nil)
        var invalidRemoval = removeSitx
        invalidRemoval.enabled = true
        precondition(!invalidRemoval.isValid)
        invalidRemoval.enabled = false
        invalidRemoval.refreshToken = "must-not-return-a-token"
        precondition(!invalidRemoval.isValid)
        print("PASS: channel selection/snapshot correlation, server provenance and bridge session identity")
        let endpoint = try CompanionEndpoint.parse(address: "https://tak.example:8447", streamPort: "8089", enrollmentPort: "8446")
        precondition(endpoint.host == "tak.example" && endpoint.streamPort == 8089 && endpoint.enrollmentPort == 8447)
        let defaultEndpoint = try CompanionEndpoint.parse(address: "tak.example", streamPort: "8089", enrollmentPort: "8446")
        precondition(defaultEndpoint.enrollmentPort == 8446)
        let firstServer = CompanionServer(endpoint: defaultEndpoint, enabled: true)
        let secondEndpoint = try CompanionEndpoint.parse(address: "other.example", streamPort: "8089", enrollmentPort: "8446")
        let secondServer = CompanionServer(endpoint: secondEndpoint)
        let servers = try CompanionServer.saving(secondServer, into: [firstServer])
        precondition(servers.count == 2 && servers[0].enabled && !servers[1].enabled)
        let restored = try JSONDecoder().decode([CompanionServer].self, from: JSONEncoder().encode(servers))
        precondition(restored == servers)
        do {
            _ = try CompanionServer.saving(CompanionServer(endpoint: defaultEndpoint), into: servers)
            fatalError("Duplicate endpoint accepted")
        } catch CompanionServer.ServerError.duplicate {}
        var edited = firstServer
        edited.enabled = false
        let updated = try CompanionServer.saving(edited, into: servers)
        precondition(updated.count == 2 && updated[0].id == firstServer.id && !updated[0].enabled)
        do {
            _ = try CompanionEndpoint.parse(address: "http://tak.example", streamPort: "8089", enrollmentPort: "8446")
            fatalError("Insecure enrollment URL accepted")
        } catch CompanionEndpoint.EndpointError.invalid {}
        let xml = "<event uid=\"test\"><detail><remarks>café</remarks></detail></event>"
        let bytes = Data(xml.utf8)
        var framer = CoTStreamFramer()
        let split = bytes.range(of: Data("é".utf8))!.lowerBound + 1
        let partial = try framer.append(Data(bytes.prefix(split)))
        precondition(partial.isEmpty)
        let events = try framer.append(Data(bytes.dropFirst(split)) + bytes)
        precondition(events.count == 2 && events[0] == bytes && events[1] == bytes)
        let cdata = Data("<event><detail><remarks><![CDATA[text </event> here]]></remarks></detail></event>".utf8)
        let cdataEvents = try framer.append(cdata)
        precondition(cdataEvents == [cdata])
        precondition(!CoTStreamFramer.isEvent(Data("<not-event/>".utf8)))
        precondition(!CoTStreamFramer.isEvent(Data("<!DOCTYPE event><event/>".utf8)))
        let encoded = try BridgeWire.Message(kind: .cot, xml: xml).encoded()
        let decoded = try BridgeWire.Message.decode(encoded)
        precondition(decoded.xml == xml)
        do {
            _ = try BridgeWire.Message.decode(Data(repeating: 0, count: 60_001))
            fatalError("Oversized message accepted")
        } catch BridgeWire.Failure.tooLarge {}
        do {
            _ = try BridgeWire.Message.decode(BridgeWire.Message(kind: .hello, version: 2).encoded())
            fatalError("Unsupported protocol accepted")
        } catch BridgeWire.Failure.unsupportedVersion {}
        do {
            _ = try BridgeWire.Message.decode(BridgeWire.Message(kind: .cot).encoded())
            fatalError("Missing CoT accepted")
        } catch BridgeWire.Failure.invalidCoT {}
        var bounded = CoTStreamFramer()
        do {
            _ = try bounded.append(Data(repeating: 65, count: 262_145))
            fatalError("Oversized stream accepted")
        } catch BridgeWire.Failure.tooLarge {}
        let requestID = UUID()
        let status = try BridgeWire.Message.decode(BridgeWire.Message(kind: .status, id: requestID, ready: false, configured: true).encoded())
        precondition(status.id == requestID && status.configured == true && status.ready == false)
        print("PASS: bounded CoT framing, split UTF-8, CDATA, XML validation and bridge messages")
    }
}