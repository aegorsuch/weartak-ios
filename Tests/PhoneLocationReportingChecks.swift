import Foundation

@main
struct PhoneLocationReportingChecks {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let uid = "3f2b8c1e-6d1a-4c0b-9a51-1f0e2d3c4b5a"
        let identity = WatchReportingIdentity(uid: uid, callSign: "ODIN <1>", team: "Dark Green", role: "K9",
            companionSelected: true, constantStrategy: false, constantInterval: 60, stationaryInterval: 3600,
            onFootInterval: 30, vehicleInterval: 5, issuedAt: now.addingTimeInterval(-60))

        // Identity transport and guards.
        let decoded = try WatchReportingIdentity.decode(contextValue: identity.contextValue())
        precondition(decoded == identity)
        let missing = try WatchReportingIdentity.decode(contextValue: nil)
        precondition(missing == nil)
        expect(.invalidField("identity payload")) { _ = try WatchReportingIdentity.decode(contextValue: "not data") }
        expect(.invalidField("identity payload")) { _ = try WatchReportingIdentity.decode(contextValue: Data("{}".utf8)) }
        _ = try identity.validated(now: now)
        var changed = identity
        changed.uid = "not-a-uuid"
        expect(.invalidUID) { _ = try changed.validated(now: now) }
        changed = identity; changed.uid = uid.uppercased()
        expect(.invalidUID) { _ = try changed.validated(now: now) }
        changed = identity; changed.version = 2
        expect(.unsupportedVersion) { _ = try changed.validated(now: now) }
        changed = identity; changed.team = " "
        expect(.invalidField("team")) { _ = try changed.validated(now: now) }
        changed = identity; changed.callSign = "bad\nname"
        expect(.invalidField("callsign")) { _ = try changed.validated(now: now) }
        changed = identity; changed.vehicleInterval = 0
        expect(.invalidField("reporting interval")) { _ = try changed.validated(now: now) }
        changed = identity; changed.issuedAt = now.addingTimeInterval(-WatchReportingIdentity.maximumAge - 1)
        expect(.stale) { _ = try changed.validated(now: now) }
        changed = identity; changed.issuedAt = now.addingTimeInterval(WatchReportingIdentity.maximumClockSkew + 1)
        expect(.futureDated) { _ = try changed.validated(now: now) }
        changed = identity; changed.companionSelected = false
        expect(.companionNotSelected) { _ = try changed.validated(now: now) }
        changed = identity; changed.issuedAt = now
        precondition(identity.hasSameSettings(as: changed) && identity != changed)
        changed.callSign = "THOR"
        precondition(!identity.hasSameSettings(as: changed))
        changed = identity; changed.callSign = "  "; changed.role = ""
        precondition(changed.resolvedCallSign == "WEARTAK-3f2b8c1e" && changed.resolvedRole == "Team Member")

        // Bounded intervals follow the watch's strategy.
        precondition(PhoneReportingPolicy.interval(for: identity, speed: 0) == 600)
        precondition(PhoneReportingPolicy.interval(for: identity, speed: 1) == 30)
        precondition(PhoneReportingPolicy.interval(for: identity, speed: 10) == 10)
        changed = identity; changed.constantStrategy = true
        precondition(PhoneReportingPolicy.interval(for: changed, speed: 0) == 60)
        var alerting = identity
        alerting.alertingInterval = 15
        alerting.alertActive = true
        _ = try alerting.validated(now: now)
        let decodedAlert = try WatchReportingIdentity.decode(contextValue: alerting.contextValue())
        precondition(decodedAlert == alerting && !identity.hasSameSettings(as: alerting))
        for constant in [false, true] {
            alerting.constantStrategy = constant
            for speed in [0.0, 1.0, 10.0] {
                precondition(PhoneReportingPolicy.interval(for: alerting, speed: speed) == 15)
            }
        }
        alerting.alertingInterval = 1
        precondition(PhoneReportingPolicy.interval(for: alerting, speed: 0) == 10)
        alerting.alertingInterval = 3600
        precondition(PhoneReportingPolicy.interval(for: alerting, speed: 0) == 600)
        alerting.alertingInterval = 0
        expect(.invalidField("alerting interval")) { _ = try alerting.validated(now: now) }
        alerting.alertingInterval = nil
        expect(.invalidField("alerting interval")) { _ = try alerting.validated(now: now) }
        alerting = identity
        alerting.alertingInterval = 15
        alerting.alertActive = false
        precondition(PhoneReportingPolicy.interval(for: alerting, speed: 1) == 30)
        alerting.constantStrategy = true
        precondition(PhoneReportingPolicy.interval(for: alerting, speed: 1) == 60)
        var legacyPayload = try JSONSerialization.jsonObject(with: identity.contextValue()) as! [String: Any]
        legacyPayload.removeValue(forKey: "alertingInterval")
        legacyPayload.removeValue(forKey: "alertActive")
        let legacy = try WatchReportingIdentity.decode(contextValue: JSONSerialization.data(withJSONObject: legacyPayload))
        precondition(legacy == identity)
        precondition(PhoneReportingPolicy.staleLifetime(interval: 30) == 75)
        precondition(PhoneReportingPolicy.staleLifetime(interval: 86_400) == 1_215)
        precondition(WatchBiometrics.staleLifetime(reportingInterval: 30) == 75)
        precondition(PhoneReportingPolicy.isDue(lastSentAt: nil, interval: 30, now: now))
        precondition(!PhoneReportingPolicy.isDue(lastSentAt: now.addingTimeInterval(-29), interval: 30, now: now))
        precondition(PhoneReportingPolicy.isDue(lastSentAt: now.addingTimeInterval(-30), interval: 30, now: now))
        precondition(PhoneReportingPolicy.isDue(lastSentAt: now.addingTimeInterval(60), interval: 30, now: now))

        // Accuracy and time guards.
        let fix = PhoneLocationFix(latitude: 38.8977, longitude: -77.0365, horizontalAccuracy: 8, altitude: 21.5,
                                   verticalAccuracy: 4, speed: 1.2, course: 270, timestamp: now.addingTimeInterval(-3))
        try PhoneReportingPolicy.validate(fix, now: now)
        var bad = fix; bad.horizontalAccuracy = 101
        expectFix(.inaccurate(101)) { try PhoneReportingPolicy.validate(bad, now: now) }
        bad = fix; bad.horizontalAccuracy = -1
        expectFix(.inaccurate(-1)) { try PhoneReportingPolicy.validate(bad, now: now) }
        bad = fix; bad.timestamp = now.addingTimeInterval(-31)
        expectFix(.stale) { try PhoneReportingPolicy.validate(bad, now: now) }
        bad = fix; bad.timestamp = now.addingTimeInterval(6)
        expectFix(.futureDated) { try PhoneReportingPolicy.validate(bad, now: now) }
        bad = fix; bad.latitude = 0; bad.longitude = 0
        expectFix(.invalidCoordinate) { try PhoneReportingPolicy.validate(bad, now: now) }
        bad = fix; bad.latitude = 91
        expectFix(.invalidCoordinate) { try PhoneReportingPolicy.validate(bad, now: now) }

        // Protocol shape and timestamps.
        let xml = PhonePLI.event(identity: identity, fix: fix, interval: 30, appVersion: "5.8.0", osVersion: "iOS 18.0", now: now)
        precondition(CoTStreamFramer.isEvent(Data(xml.utf8)), xml)
        _ = try BridgeWire.Message.decode(BridgeWire.Message(kind: .cot, xml: xml).encoded())
        precondition(PhonePLI.header(xml)! == (uid, "a-f-G-U-C"))
        precondition(xml.contains("time=\"2027-01-15T08:00:00.000Z\""), xml)
        precondition(xml.contains("start=\"2027-01-15T07:59:57.000Z\""), xml)
        precondition(xml.contains("stale=\"2027-01-15T08:01:15.000Z\""), xml)
        precondition(xml.contains("how=\"m-g\""))
        precondition(xml.contains("<point lat=\"38.8977000\" lon=\"-77.0365000\" hae=\"21.5\" ce=\"8.0\" le=\"4.0\"/>"), xml)
        precondition(xml.contains("<contact callsign=\"ODIN &lt;1&gt;\" endpoint=\"*:-1:stcp\"/>"))
        precondition(xml.contains("<__group name=\"Dark Green\" role=\"K9\"/>"))
        precondition(xml.contains("<uid Droid=\"ODIN &lt;1&gt;\"/>"))
        precondition(xml.contains("platform=\"WearTAK Companion\"") && xml.contains("geopointsrc=\"GPS\""))
        precondition(xml.contains("<track course=\"270.0\" speed=\"1.2\"/>"))
        var renamedIdentity = identity
        renamedIdentity.callSign = "THOR"
        let renamedPLI = PhonePLI.event(identity: renamedIdentity, fix: fix, interval: 30,
                                        appVersion: "5.8.0", osVersion: "iOS 18.0", now: now)
        precondition(PhonePLI.header(renamedPLI)! == (uid, "a-f-G-U-C"))
        precondition(renamedPLI.contains("<contact callsign=\"THOR\" endpoint=\"*:-1:stcp\"/>"))
        var noAltitude = fix; noAltitude.verticalAccuracy = -1; noAltitude.speed = -1
        let flat = PhonePLI.event(identity: identity, fix: noAltitude, interval: 30, appVersion: "1", osVersion: "iOS", now: now)
        precondition(flat.contains("hae=\"9999999\"") && flat.contains("le=\"9999999\"") && !flat.contains("<track"))
        var future = fix; future.timestamp = now.addingTimeInterval(2)
        let clamped = PhonePLI.event(identity: identity, fix: future, interval: 30, appVersion: "1", osVersion: "iOS", now: now)
        precondition(clamped.contains("start=\"2027-01-15T08:00:00.000Z\""), clamped)

        // Watch biometrics: WearOS-compatible remarks and <biometrics>; stale or missing vitals become N/A.
        precondition(!xml.contains("<biometrics"))
        let vitals = WatchBiometrics(heartRate: 72, exertion: 38, measuredAt: now.addingTimeInterval(-60),
                                     ageYears: 35, batdokCotEnabled: true)
        let decodedVitals = WatchBiometrics.decode(contextValue: try vitals.contextValue())
        precondition(decodedVitals == vitals)
        let bio = PhonePLI.event(identity: identity, fix: fix, interval: 30, appVersion: "1", osVersion: "iOS",
                                 biometrics: vitals, now: now)
        precondition(bio.contains("<remarks>Exert:38%;HR:72</remarks>"), bio)
        precondition(bio.contains("<_atmist_ age=\"35\""), bio)
        precondition(bio.contains("(HR,72,"), bio)
        precondition(bio.contains("</_atmist_>"), bio)
        precondition(bio.contains("<biometrics><device><model>WATCHOS</model><uid>\(uid)</uid><hr>72</hr><exert>38</exert></device></biometrics>"), bio)
        precondition(CoTStreamFramer.isEvent(Data(bio.utf8)))
        var batdokDisabledVitals = vitals
        batdokDisabledVitals.batdokCotEnabled = false
        let batdokDisabled = PhonePLI.event(identity: identity, fix: fix, interval: 30, appVersion: "1", osVersion: "iOS",
                                            biometrics: batdokDisabledVitals, now: now)
        precondition(batdokDisabled.contains("<remarks>Exert:38%;HR:72</remarks>"), batdokDisabled)
        precondition(!batdokDisabled.contains("<_atmist_") && !batdokDisabled.contains("<biometrics"), batdokDisabled)
        var cutoffVitals = vitals; cutoffVitals.measuredAt = now.addingTimeInterval(-75)
        let atCutoff = PhonePLI.event(identity: identity, fix: fix, interval: 30, appVersion: "1", osVersion: "iOS",
                                      biometrics: cutoffVitals, now: now)
        precondition(atCutoff.contains("<hr>72</hr>"), atCutoff)
        var oldVitals = cutoffVitals; oldVitals.measuredAt = now.addingTimeInterval(-76)
        let stale = PhonePLI.event(identity: identity, fix: fix, interval: 30, appVersion: "1", osVersion: "iOS",
                                   biometrics: oldVitals, now: now)
        precondition(stale.contains("<remarks>Exert:N/A%;HR:N/A</remarks>") && stale.contains("<hr>N/A</hr>"), stale)
        let noHR = PhonePLI.event(identity: identity, fix: fix, interval: 30, appVersion: "1", osVersion: "iOS",
                                  biometrics: WatchBiometrics(), now: now)
        precondition(noHR.contains("<exert>N/A</exert>"))
        precondition(WatchBiometrics.decode(contextValue: "bad") == nil)

        // Duplicate watch PLI suppression only affects the same user's position report.
        let watchPLI = "<event version=\"2.0\" uid=\"\(uid)\" type=\"a-f-G-U-C\" time=\"t\" start=\"t\" stale=\"t\" how=\"m-g\"><point lat=\"1\" lon=\"1\" hae=\"0\" ce=\"0\" le=\"0\"/><detail/></event>"
        precondition(PhonePLI.isSelfPLI(watchPLI, uid: uid))
        precondition(!PhonePLI.isSelfPLI(watchPLI, uid: "11111111-2222-3333-4444-555555555555"))
        let alert = watchPLI.replacingOccurrences(of: "uid=\"\(uid)\" type=\"a-f-G-U-C\"",
                                                  with: "uid=\"\(uid)-alert-Gunshot\" type=\"b-a-o\"")
        let point = watchPLI.replacingOccurrences(of: "uid=\"\(uid)\" type=\"a-f-G-U-C\"",
                                                  with: "uid=\"\(UUID().uuidString)\" type=\"a-h-G\"")
        let sameUIDOtherType = watchPLI.replacingOccurrences(of: "a-f-G-U-C", with: "b-a-o-can")
        precondition(!PhonePLI.isSelfPLI(alert, uid: uid) && !PhonePLI.isSelfPLI(point, uid: uid))
        precondition(!PhonePLI.isSelfPLI(sameUIDOtherType, uid: uid) && !PhonePLI.isSelfPLI("<event", uid: uid))
        precondition(!PhoneReportingPolicy.suppressesWatchPLI(lastPhoneReportAt: nil, interval: 30, now: now))
        precondition(PhoneReportingPolicy.suppressesWatchPLI(lastPhoneReportAt: now.addingTimeInterval(-120), interval: 30, now: now))
        precondition(!PhoneReportingPolicy.suppressesWatchPLI(lastPhoneReportAt: now.addingTimeInterval(-121), interval: 30, now: now))
        precondition(!PhoneReportingPolicy.suppressesWatchPLI(lastPhoneReportAt: now.addingTimeInterval(10), interval: 30, now: now))
        precondition(PhoneReportingPolicy.canUsePhonePLI(lastPhoneReportAt: now, latestFix: fix, interval: 30, now: now))
        precondition(!PhoneReportingPolicy.canUsePhonePLI(lastPhoneReportAt: nil, latestFix: fix, interval: 30, now: now))
        precondition(!PhoneReportingPolicy.canUsePhonePLI(lastPhoneReportAt: now, latestFix: nil, interval: 30, now: now))
        bad = fix; bad.timestamp = now.addingTimeInterval(-31)
        precondition(!PhoneReportingPolicy.canUsePhonePLI(lastPhoneReportAt: now, latestFix: bad, interval: 600, now: now))
        bad = fix; bad.horizontalAccuracy = 101
        precondition(!PhoneReportingPolicy.canUsePhonePLI(lastPhoneReportAt: now, latestFix: bad, interval: 30, now: now))

        // Start/stop gate: no reporting before identity, without servers, or after authorization is revoked.
        func gate(servers: Int = 1, identity result: Result<WatchReportingIdentity, WatchReportingIdentity.Failure> = .success(identity),
                  auth: PhoneAuthorization = .whenInUse, precise: Bool = true, services: Bool = true,
                  active: Bool = true, running: Bool = false) -> PhoneReportingGate.Decision {
            PhoneReportingGate.decide(enabledConfiguredServers: servers, identity: result, authorization: auth,
                                      preciseLocation: precise, servicesEnabled: services, appActive: active, alreadyRunning: running)
        }
        precondition(gate() == .run)
        precondition(gate(servers: 0) == .blocked("Enable a TAK server with a certificate."))
        precondition(gate(identity: .failure(.missing)) == .blocked(WatchReportingIdentity.Failure.missing.localizedDescription))
        precondition(gate(identity: .failure(.mismatchedUID)) == .blocked(WatchReportingIdentity.Failure.mismatchedUID.localizedDescription))
        precondition(gate(auth: .notDetermined) == .requestWhenInUse)
        precondition(gate(auth: .notDetermined, active: false) != .requestWhenInUse)
        if case .blocked = gate(auth: .denied, running: true) {} else { fatalError("Revoked authorization must stop reporting") }
        if case .blocked = gate(auth: .restricted) {} else { fatalError("Restricted authorization must block") }
        if case .blocked = gate(precise: false) {} else { fatalError("Approximate location must block") }
        if case .blocked = gate(services: false, running: true) {} else { fatalError("Disabled services must block") }
        if case .blocked = gate(active: false) {} else { fatalError("While-in-use must not start from background") }
        precondition(gate(active: false, running: true) == .run)
        precondition(gate(auth: .always, active: false) == .run)
        print("PASS: watch identity guards, alert override and cancellation, legacy identity compatibility, bounded intervals, fix accuracy/time guards, PLI shape/timestamps, duplicate PLI suppression and start/stop gating")
        precondition(PhoneBackgroundAdvice.message(hasServers: false, authorization: .whenInUse,
            preciseLocation: true, servicesEnabled: true) == nil)
        precondition(PhoneBackgroundAdvice.message(hasServers: true, authorization: .always,
            preciseLocation: true, servicesEnabled: true) == nil)
        for auth in [PhoneAuthorization.whenInUse, .notDetermined, .denied] {
            precondition(PhoneBackgroundAdvice.message(hasServers: true, authorization: auth,
                preciseLocation: true, servicesEnabled: true)?.contains("Always") == true)
            precondition(PhoneBackgroundAdvice.watchReason(authorization: auth, preciseLocation: true,
                servicesEnabled: true) == "set Location to Always")
        }
        precondition(PhoneBackgroundAdvice.message(hasServers: true, authorization: .always,
            preciseLocation: false, servicesEnabled: true)?.contains("Precise") == true)
        precondition(PhoneBackgroundAdvice.message(hasServers: true, authorization: .always,
            preciseLocation: true, servicesEnabled: false)?.contains("Location Services") == true)
        precondition(PhoneBackgroundAdvice.watchReason(authorization: .always, preciseLocation: true,
            servicesEnabled: true) == nil)
        print("PASS: Always-location advice for keeping the watch connected while the phone is locked")
    }

    private static func expect(_ failure: WatchReportingIdentity.Failure, _ body: () throws -> Void) {
        do { try body(); fatalError("Expected \(failure)") }
        catch let error as WatchReportingIdentity.Failure { precondition(error == failure, "\(error) != \(failure)") }
        catch { fatalError("Unexpected \(error)") }
    }

    private static func expectFix(_ failure: PhoneReportingPolicy.FixFailure, _ body: () throws -> Void) {
        do { try body(); fatalError("Expected \(failure)") }
        catch let error as PhoneReportingPolicy.FixFailure { precondition(error == failure, "\(error) != \(failure)") }
        catch { fatalError("Unexpected \(error)") }
    }
}
