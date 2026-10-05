import Foundation

struct SitxGroup: Codable, Identifiable, Equatable {
    let flowTag: String
    let name: String
    var id: String { flowTag }

    enum CodingKeys: String, CodingKey {
        case flowTag = "flow_tag"
        case name
    }
}

/// Sit(x) Device API details shared by the watch client and the Companion setup flow.
enum SitxAPI {
    static let clientID = "D4RTE81TJjccxlc8LPD7QQ"

    /// Turns an organization name or URL into `https://<org>.sitx.io`, rejecting anything else.
    static func normalizedHost(_ value: String) -> String? {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !input.isEmpty else { return nil }
        let urlText = input.contains("://") ? input : "https://" + input
        guard var components = URLComponents(string: urlText),
              components.scheme == "https" || components.scheme == "http",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              var hostname = components.host else { return nil }
        if hostname != "sitx.io", !hostname.hasSuffix(".sitx.io") {
            hostname += ".sitx.io"
        }
        let labels = hostname.split(separator: ".", omittingEmptySubsequences: false)
        guard hostname.count <= 253, labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { byte in
                (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
            }
        }) else { return nil }
        components.scheme = "https"
        components.host = hostname
        components.path = ""
        return components.string
    }

    /// Extracts a short, human-readable reason from a Sit(x) error body.
    static func serverMessage(from data: Data) -> String? {
        var text: String?
        if let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for key in ["error_description", "message", "detail", "error"] {
                if let value = body[key] as? String, !value.isEmpty { text = value; break }
                if let values = body[key] as? [String], let first = values.first { text = first; break }
            }
        } else if let raw = String(data: data, encoding: .utf8), !raw.contains("<") {
            text = raw
        }
        guard let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else { return nil }
        return cleaned.count > 120 ? String(cleaned.prefix(117)) + "..." : cleaned
    }

    static func networkReason(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet: return "no internet path"
        case .timedOut: return "timed out"
        case .cannotFindHost, .dnsLookupFailed: return "host not found"
        case .cannotConnectToHost: return "cannot reach host"
        case .networkConnectionLost: return "connection lost"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot: return "TLS failed"
        case .badServerResponse: return "bad server response"
        default: return "URL error"
        }
    }

    /// Display form of a normalized host, e.g. `team.sitx.io`.
    static func displayHost(_ host: String) -> String {
        host.replacingOccurrences(of: "https://", with: "")
    }

    /// Organization name for the Address editor, e.g. `team` for `https://team.sitx.io`.
    static func organization(_ host: String) -> String {
        var organization = displayHost(host)
        if organization.hasSuffix(".sitx.io") { organization.removeLast(".sitx.io".count) }
        return organization
    }
}
