import Foundation

struct CompanionServer: Codable, Identifiable, Equatable {
    let id: UUID
    var host: String
    var port: Int
    var enrollmentPort: Int
    var enabled: Bool

    var endpoint: CompanionEndpoint {
        CompanionEndpoint(host: host, streamPort: port, enrollmentPort: enrollmentPort)
    }

    init(id: UUID = UUID(), endpoint: CompanionEndpoint, enabled: Bool = false) {
        self.id = id
        host = endpoint.host
        port = endpoint.streamPort
        enrollmentPort = endpoint.enrollmentPort
        self.enabled = enabled
    }

    static func saving(_ server: Self, into servers: [Self]) throws -> [Self] {
        guard !servers.contains(where: { $0.id != server.id && $0.endpoint.key == server.endpoint.key }) else {
            throw ServerError.duplicate
        }
        var updated = servers
        if let index = updated.firstIndex(where: { $0.id == server.id }) { updated[index] = server }
        else { updated.append(server) }
        return updated
    }

    enum ServerError: LocalizedError {
        case duplicate
        var errorDescription: String? { "A server with this IP/host and port already exists." }
    }
}