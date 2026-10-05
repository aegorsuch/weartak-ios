import Foundation

@main
struct CompanionServerChecks {
    static func main() throws {
        let endpoint = CompanionEndpoint(host: "tak.example.gov", streamPort: 8089, enrollmentPort: 8446)
        let original = CompanionServer(endpoint: endpoint)
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
        let legacyServer = try JSONDecoder().decode(CompanionServer.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        precondition(legacyServer.streamTLSName == nil && legacyServer.expectedStreamTLSName == endpoint.host)
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
        print("PASS: stream TLS override validation, persistence, legacy records, clearing and unchanged connection address")
    }
}
