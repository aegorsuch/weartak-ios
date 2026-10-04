import Foundation

struct CompanionServer: Codable, Identifiable, Equatable {
    let id: UUID
    var host: String
    var port: Int
    var enrollmentPort: Int
    var enabled: Bool
    var streamTLSName: String?

    var endpoint: CompanionEndpoint {
        CompanionEndpoint(host: host, streamPort: port, enrollmentPort: enrollmentPort)
    }

    init(id: UUID = UUID(), endpoint: CompanionEndpoint, enabled: Bool = false, streamTLSName: String? = nil) {
        self.id = id
        host = endpoint.host
        port = endpoint.streamPort
        enrollmentPort = endpoint.enrollmentPort
        self.enabled = enabled
        self.streamTLSName = streamTLSName
    }

    var expectedStreamTLSName: String { streamTLSName ?? host }

    static func validatedStreamTLSName(_ input: String) throws -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard name.utf8.count <= 253, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { throw ServerError.invalidTLSName }
        return name
    }

    static func saving(_ server: Self, into servers: [Self]) throws -> [Self] {
        var server = server
        server.streamTLSName = try validatedStreamTLSName(server.streamTLSName ?? "")
        guard !servers.contains(where: { $0.id != server.id && $0.endpoint.key == server.endpoint.key }) else {
            throw ServerError.duplicate
        }
        var updated = servers
        if let index = updated.firstIndex(where: { $0.id == server.id }) { updated[index] = server }
        else { updated.append(server) }
        return updated
    }

    enum ServerError: LocalizedError {
        case duplicate, invalidTLSName
        var errorDescription: String? {
            switch self {
            case .duplicate: return "A server with this IP/host and port already exists."
            case .invalidTLSName: return "Enter an administrator-confirmed DNS name only, without a URL, port, wildcard, or path."
            }
        }
    }
}