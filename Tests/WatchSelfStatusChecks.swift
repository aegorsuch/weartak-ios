import Foundation

enum WatchSelfStatusChecks {
    static func run(identity: WatchReportingIdentity, fix: PhoneLocationFix, now: Date) throws {
        func snapshot(session: String = "connection-a", seq: Int64 = 0,
                      ppe: WatchSelfStatus.PPE? = .init(level: "MOPP 2",
                          savedAt: "2027-01-15T07:00:00Z"),
                      hr: Int? = 72, measuredAt: Date? = nil) -> WatchSelfStatus {
            WatchSelfStatus(version: 1, session: session, seq: seq, deviceUid: identity.uid, model: "WATCHOS",
                ppe: ppe, physio: hr.map { .init(hr: $0,
                    measuredAt: WatchSelfStatus.timestamp(measuredAt ?? now)) })
        }
        func reject(_ body: () throws -> Void) {
            do { try body(); preconditionFailure("Invalid self-status was accepted") }
            catch {}
        }
        let value = snapshot()
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(WatchSelfStatus.self, from: encoded)
        precondition(decoded == value)
        precondition(value.remarks == "MOPP2; HR: 72 bpm @ 08:00:00Z")
        let userRemarks = "Keep <&> user text\nWearTAK PLI user note"
        precondition(value.appendingRemarks(to: userRemarks) == "\(userRemarks)\n\(value.remarks)")
        precondition(value.appendingRemarks(to: "") == value.remarks)
        for level in WatchSelfStatus.levels {
            let ppeOnly = snapshot(ppe: .init(level: level, savedAt: WatchSelfStatus.timestamp(now)), hr: nil)
            precondition(ppeOnly.remarks == (level == "None" ? "" : level.replacingOccurrences(of: " ", with: "")))
            precondition(ppeOnly.biometrics(escapedUID: identity.uid).isEmpty)
        }
        for age in [-30.0, 0, 120] {
            precondition(snapshot(measuredAt: now.addingTimeInterval(-age)).fresh(now: now).physio?.hr == 72)
        }
        for age in [-30.001, 120.001, 900] {
            let fresh = snapshot(measuredAt: now.addingTimeInterval(-age)).fresh(now: now)
            precondition(fresh.physio == nil && fresh.remarks == "MOPP2")
        }
        var receiver = WatchSelfStatusReceiver()
        try receiver.receive(value, uid: identity.uid, model: "WATCHOS", now: now)
        reject { try receiver.receive(value, uid: identity.uid, model: "WATCHOS", now: now.addingTimeInterval(200)) }
        reject { try receiver.receive(snapshot(seq: -1), uid: identity.uid, model: "WATCHOS", now: now) }
        reject { try receiver.receive(snapshot(session: "other", seq: 1), uid: identity.uid, model: "WATCHOS", now: now) }
        reject { try receiver.receive(snapshot(seq: 1), uid: "wrong UID", model: "WATCHOS", now: now) }
        reject { try receiver.receive(snapshot(seq: 1), uid: identity.uid, model: "GARMIN", now: now) }
        precondition(receiver.current(now: now.addingTimeInterval(299.999))?.remarks == "MOPP2")
        precondition(receiver.current(now: now.addingTimeInterval(300)) == nil)
        reject { try receiver.receive(value, uid: identity.uid, model: "WATCHOS", now: now.addingTimeInterval(301)) }
        try receiver.receive(snapshot(seq: 1, ppe: nil, hr: nil), uid: identity.uid, model: "WATCHOS", now: now)
        precondition(receiver.current(now: now)?.remarks == "")
        receiver.disconnect()
        precondition(receiver.current(now: now) == nil)
        try receiver.receive(snapshot(session: "connection-b"), uid: identity.uid, model: "WATCHOS", now: now)
        reject { try receiver.receive(value, uid: identity.uid, model: "WATCHOS", now: now) }
        let emptyData = try JSONEncoder().encode(snapshot(ppe: nil, hr: nil))
        let empty = try JSONSerialization.jsonObject(with: emptyData) as! [String: Any]
        precondition(empty["ppe"] is NSNull && empty["physio"] is NSNull)
        for key in ["ppe", "physio"] {
            var missing = empty
            missing.removeValue(forKey: key)
            let data = try JSONSerialization.data(withJSONObject: missing)
            reject { _ = try JSONDecoder().decode(WatchSelfStatus.self, from: data) }
        }
        for change in [["version": 2], ["version": true], ["seq": -1], ["seq": 1.5],
                       ["session": ""], ["session": String(repeating: "x", count: 129)],
                       ["model": "SPI"], ["deviceUid": ""]] as [[String: Any]] {
            var bad = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            for (key, value) in change { bad[key] = value }
            let data = try JSONSerialization.data(withJSONObject: bad)
            reject { _ = try JSONDecoder().decode(WatchSelfStatus.self, from: data) }
        }
        for hr in [19, 251] { reject { _ = try snapshot(hr: hr).validated() } }
        for hr in [20, 250] { _ = try snapshot(hr: hr).validated() }
        reject { _ = try snapshot(ppe: .init(level: "MOPP 5", savedAt: WatchSelfStatus.timestamp(now))).validated() }
        reject { _ = try snapshot(ppe: .init(level: "None", savedAt: "not a timestamp")).validated() }
        let legacyPPE = snapshot(ppe: .init(level: "MOPP 0", savedAt: nil), hr: nil)
        let legacyData = try JSONEncoder().encode(legacyPPE)
        let legacyObject = try JSONSerialization.jsonObject(with: legacyData) as! [String: Any]
        precondition((legacyObject["ppe"] as! [String: Any])["savedAt"] is NSNull)
        precondition(legacyPPE.remarks == "MOPP0")
        let legacyDecoded = try JSONDecoder().decode(WatchSelfStatus.self, from: legacyData)
        precondition(legacyDecoded == legacyPPE)
        var noSaveTime = legacyObject
        noSaveTime["ppe"] = ["level": "MOPP 0"]
        let noSaveData = try JSONSerialization.data(withJSONObject: noSaveTime)
        reject { _ = try JSONDecoder().decode(WatchSelfStatus.self, from: noSaveData) }
        var extended = snapshot()
        extended.physio?.exert = 0.45
        let sameSampleTime = extended.physio?.measuredAt
        extended.physio?.exertMeasuredAt = sameSampleTime
        precondition(extended.remarks == "MOPP2; HR: 72 bpm @ 08:00:00Z; Exert: 45% @ 08:00:00Z")
        precondition(extended.biometrics(escapedUID: identity.uid).contains(
            "<exert sampleTime=\"2027-01-15T08:00:00.000Z\">0.45</exert>"))
        extended.physio?.measuredAt = WatchSelfStatus.timestamp(now.addingTimeInterval(-121))
        let exertOnly = extended.fresh(now: now)
        precondition(exertOnly.physio?.hr == nil && exertOnly.physio?.exert == 0.45)
        precondition(exertOnly.remarks == "MOPP2; Exert: 45% @ 08:00:00Z")
        let exertData = try JSONEncoder().encode(exertOnly)
        let exertObject = try JSONSerialization.jsonObject(with: exertData) as! [String: Any]
        let physioObject = exertObject["physio"] as! [String: Any]
        precondition(physioObject["hr"] == nil && physioObject["measuredAt"] == nil)
        var nullHR = exertObject
        var nullPhysio = physioObject
        nullPhysio["hr"] = NSNull()
        nullHR["physio"] = nullPhysio
        let nullData = try JSONSerialization.data(withJSONObject: nullHR)
        reject { _ = try JSONDecoder().decode(WatchSelfStatus.self, from: nullData) }
        var skinFixture = exertOnly
        skinFixture.physio?.sktF = 95
        skinFixture.physio?.sktFMeasuredAt = WatchSelfStatus.timestamp(now)
        precondition(skinFixture.biometrics(escapedUID: identity.uid).contains(
            "<skt sampleTime=\"2027-01-15T08:00:00.000Z\">35.0</skt>"))
        for exert in [-0.01, 1.01] {
            var invalid = extended; invalid.physio?.exert = exert
            reject { _ = try invalid.validated() }
        }

        let xml = PhonePLI.event(identity: identity, fix: fix, interval: 30,
            appVersion: "1", osVersion: "iOS", selfStatus: value, now: now)
        precondition(xml.contains("<remarks>MOPP2; HR: 72 bpm @ 08:00:00Z</remarks>"), xml)
        precondition(xml.contains("<biometrics version=\"1\"><device sampleTime=\"2027-01-15T08:00:00.000Z\"><model>WATCHOS</model><uid>\(identity.uid)</uid><hr>72</hr></device></biometrics>"), xml)
        precondition(!xml.contains("<exert>") && !xml.contains("<_atmist_") && !xml.contains("WearTAK PLI"))
        let clean = PhonePLI.event(identity: identity, fix: fix, interval: 30,
            appVersion: "1", osVersion: "iOS", now: now)
        precondition(!clean.contains("<remarks>") && !clean.contains("<biometrics"))
        precondition(PhonePLI.header(clean)?.uid == identity.uid)
        precondition(clean.contains("lat=\"38.8977000\"") && clean.contains("callsign=\"ODIN &lt;1&gt;\""))
        let stale = PhonePLI.event(identity: identity, fix: fix, interval: 900,
            appVersion: "1", osVersion: "iOS", selfStatus: snapshot(measuredAt: now.addingTimeInterval(-121)), now: now)
        precondition(stale.contains("<remarks>MOPP2</remarks>") && !stale.contains("<biometrics"))
        let message = BridgeWire.Message(kind: .selfStatus, selfStatusPayload: value)
        let decodedMessage = try BridgeWire.Message.decode(message.encoded())
        precondition(decodedMessage.selfStatusPayload == value)
        reject { _ = try BridgeWire.Message.decode(BridgeWire.Message(kind: .selfStatus).encoded()) }
        reject { _ = try BridgeWire.Message.decode(BridgeWire.Message(kind: .hello, selfStatusPayload: value).encoded()) }
        let source = try String(contentsOfFile: "WearTAK Watch App/WatchCompanionOutput.swift", encoding: .utf8)
        let publisher = source.components(separatedBy: "private func publishSelfStatus() {")[1]
            .components(separatedBy: "func publishIdentity(")[0]
        precondition(publisher.contains("sendMessageData") && !publisher.contains("updateApplicationContext"))
        precondition(publisher.contains("settings.moppSavedAt") && publisher.contains("selfStatusVersion =="))
        print("PASS: SELF_STATUS v1 capability/shape, source/session/sequence isolation, null/off cleanup, per-metric 120s/+30s freshness, 300s TTL, MOPP0 remarks, real exertion and proxy CoT")
    }
}
