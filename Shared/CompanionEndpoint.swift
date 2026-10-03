import Foundation

struct CompanionEndpoint {
    let host: String
    let streamPort: Int
    let enrollmentPort: Int
    var key: String { "\(host.lowercased()):\(streamPort)" }

    static func parse(address: String, streamPort: String, enrollmentPort: String) throws -> Self {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = input.contains("://") ? input : "https://" + input
        guard let url = URLComponents(string: text), url.scheme == "https", let host = url.host,
              !host.isEmpty, !host.contains(where: { $0.isWhitespace }), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              let stream = Int(streamPort), (1...65535).contains(stream),
              let enrollment = url.port ?? Int(enrollmentPort), (1...65535).contains(enrollment) else {
            throw EndpointError.invalid
        }
        return Self(host: host, streamPort: stream, enrollmentPort: enrollment)
    }

    enum EndpointError: LocalizedError {
        case invalid
        var errorDescription: String? { "Enter a host or HTTPS server URL and ports from 1 to 65535." }
    }
}