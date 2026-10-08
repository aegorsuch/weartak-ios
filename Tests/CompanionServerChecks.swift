import Foundation

@main
struct CompanionServerChecks {
    static func main() throws {
        let endpoint = CompanionEndpoint(host: "tak.example.gov", streamPort: 8089, enrollmentPort: 8446)
        let original = CompanionServer(endpoint: endpoint)
        precondition(original.displayName == "tak.example.gov:8089")
        precondition(original.displayLabel == original.addressLabel)
        let named = try CompanionServer.saving(
            CompanionServer(id: original.id, endpoint: endpoint, name: " Training \n"), into: [original])
        precondition(named[0].name == "Training")
        precondition(named[0].displayName == "Training")
        precondition(named[0].displayLabel == "Training (tak.example.gov:8089)")
        precondition(named[0].endpoint.key == original.endpoint.key &&
                     named[0].enrollmentPort == original.enrollmentPort && named[0].id == original.id)
        let namedRestored = try JSONDecoder().decode([CompanionServer].self, from: JSONEncoder().encode(named))
        precondition(namedRestored == named)
        var unnamed = named[0]
        unnamed.name = " \n"
        let unnamedSaved = try CompanionServer.saving(unnamed, into: named)
        precondition(unnamedSaved[0].name == nil && unnamedSaved[0].displayLabel == original.addressLabel)
        precondition(original.expectedStreamTLSName == endpoint.host)
        precondition(original.expectedAPITLSName == endpoint.host)
        let blank = try CompanionServer.validatedStreamTLSName(" \n")
        precondition(blank == nil)
        let normalized = try CompanionServer.validatedStreamTLSName(" TAKSERVER.Example \n")
        precondition(normalized == "takserver.example")
        let singleLabel = try CompanionServer.validatedStreamTLSName(" TAKSERVER2 ")
        precondition(singleLabel == "takserver2")
        let legacyIdentity = CompanionServer(endpoint: endpoint, streamTLSName: singleLabel)
        precondition(legacyIdentity.expectedStreamTLSName == "takserver2" &&
                     legacyIdentity.endpoint.host == endpoint.host &&
                     legacyIdentity.endpoint.streamPort == endpoint.streamPort &&
                     legacyIdentity.endpoint.enrollmentPort == endpoint.enrollmentPort)
        let override = CompanionServer(id: original.id, endpoint: endpoint, streamTLSName: normalized)
        let saved = try CompanionServer.saving(override, into: [original])
        precondition(saved.count == 1 && saved[0].endpoint.key == original.endpoint.key)
        precondition(saved[0].expectedStreamTLSName == "takserver.example")
        let restored = try JSONDecoder().decode([CompanionServer].self, from: JSONEncoder().encode(saved))
        precondition(restored == saved)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(override)) as! [String: Any]
        legacy.removeValue(forKey: "streamTLSName")
        legacy.removeValue(forKey: "name")
        let legacyServer = try JSONDecoder().decode(CompanionServer.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        precondition(legacyServer.streamTLSName == nil && legacyServer.expectedStreamTLSName == endpoint.host)
        precondition(legacyServer.name == nil && legacyServer.displayName == original.addressLabel)
        precondition(legacyServer.apiTLSName == nil && legacyServer.expectedAPITLSName == endpoint.host)
        let apiOverride = CompanionServer(id: original.id, endpoint: endpoint,
                                          streamTLSName: "stream.example", apiTLSName: " TAKSERVER2 ")
        let apiSaved = try CompanionServer.saving(apiOverride, into: [original])
        precondition(apiSaved[0].expectedAPITLSName == "takserver2" &&
                     apiSaved[0].expectedStreamTLSName == "stream.example" &&
                     apiSaved[0].endpoint.key == endpoint.key &&
                     apiSaved[0].enrollmentPort == endpoint.enrollmentPort)
        let apiRestored = try JSONDecoder().decode([CompanionServer].self, from: JSONEncoder().encode(apiSaved))
        precondition(apiRestored == apiSaved)
        var apiCleared = apiSaved[0]
        apiCleared.apiTLSName = " "
        let apiReset = try CompanionServer.saving(apiCleared, into: apiSaved)
        precondition(apiReset[0].apiTLSName == nil && apiReset[0].expectedAPITLSName == endpoint.host &&
                     apiReset[0].expectedStreamTLSName == "stream.example")
        for invalid in ["https://takserver", "takserver:8089", "*.example.gov", "a/b", "a b", "-bad", "bad-", "a..b",
                        String(repeating: "a", count: 64)] {
            do {
                _ = try CompanionServer.validatedStreamTLSName(invalid)
                fatalError("Invalid TLS name accepted: \(invalid)")
            } catch CompanionServer.ServerError.invalidTLSName {}
            do {
                _ = try CompanionServer.saving(CompanionServer(endpoint: endpoint, apiTLSName: invalid), into: [])
                fatalError("Invalid API TLS name accepted: \(invalid)")
            } catch CompanionServer.ServerError.invalidTLSName {}
        }
        var cleared = override
        cleared.streamTLSName = ""
        let reset = try CompanionServer.saving(cleared, into: saved)
        precondition(reset[0].streamTLSName == nil && reset[0].expectedStreamTLSName == endpoint.host)
        print("PASS: server names, TLS overrides, persistence, legacy records, clearing and unchanged connection address")
    }
}
