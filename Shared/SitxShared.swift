import Foundation

/// Only for device-code polling; never replay requests that rotate refresh tokens.
struct SitxAuthorizationRetry {
    private(set) var retries = 0

    mutating func delay(for error: Error, pollingInterval: TimeInterval) -> TimeInterval? {
        guard let error = error as? URLError, retries < 3 else { return nil }
        switch error.code {
        case .networkConnectionLost, .timedOut, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            let delay = max(pollingInterval, 5 * pow(2, Double(retries)))
            retries += 1
            return delay
        default:
            return nil
        }
    }

    static func status(_ failure: String) -> String {
        "Retrying authorization: " + failure
    }
}

/// Display-only account details from Sit(x) token claims; never used for authorization decisions.
struct SitxLinkedAccount: Equatable {
    var email: String?
    var callsign: String?
    /// Only access tokens carry this; Sit(x) reports `user` for person accounts.
    var accessType: String?

    init?(jwt: String?) {
        let parts = jwt?.split(separator: ".", omittingEmptySubsequences: false) ?? []
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func text(_ key: String) -> String? {
            (claims[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        email = text("user_email")
        callsign = text("callsign")
        accessType = text("access_type")
        guard email != nil || callsign != nil else { return nil }
    }

    /// Keeps a known access type when a newer refresh token (which omits it) names the same account.
    func updated(with newer: SitxLinkedAccount?) -> SitxLinkedAccount? {
        guard var newer else { return self }
        if newer.accessType == nil, newer.email == email, newer.callsign == callsign { newer.accessType = accessType }
        return newer
    }

    var isNonPersonEntity: Bool { accessType.map { $0.lowercased() != "user" } ?? false }

    var label: String {
        let name = email ?? callsign ?? ""
        return isNonPersonEntity ? "NPE · " + name : name
    }

    /// Shown when the device is not linked to a person account.
    static let unlinkedLabel = "NPE"

    static func displayLabel(_ account: SitxLinkedAccount?) -> String {
        guard let label = account?.label, !label.isEmpty else { return unlinkedLabel }
        return label
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

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

    /// Shows 8-character device codes as `XXXX-XXXX`, matching the Sit(x) pairing page.
    static func displayUserCode(_ code: String) -> String {
        let characters = code.filter { $0.isLetter || $0.isNumber }.uppercased()
        guard characters.count == 8 else { return code }
        return "\(characters.prefix(4))-\(characters.suffix(4))"
    }

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

    /// Explains a `sequestered_status` from a token response; nil when the device may take part in SA.
    /// A sequestered device is authenticated but muted until the reason is resolved in the Sit(x) portal.
    static func sequesteredReason(_ status: Any?) -> String? {
        guard let status = status as? String, !status.isEmpty, status != "not_sequestered" else { return nil }
        switch status {
        case "over_plan_user_devices_sequestered":
            return "Sit(x) device limit reached for this account; remove an old device in the Sit(x) portal"
        case "activation_required_sequestered":
            return "Sit(x) device needs activation; open Sequestered Devices in the Sit(x) portal"
        case "over_plan_concurrent_connections_sequestered":
            return "Sit(x) organization is at its active-device limit; retrying"
        case "admin_approval_required_sequestered":
            return "Sit(x) device awaiting administrator approval"
        default:
            return "Sit(x) device sequestered (\(status))"
        }
    }

    /// Plain-language text for OAuth / device-flow error codes (RFC 6749 and RFC 8628).
    static func oauthErrorMessage(_ code: String) -> String? {
        switch code {
        case "access_denied": return "authorization was denied"
        case "expired_token": return "code expired; retry"
        case "invalid_grant": return "authorization is no longer valid; select Re-auth"
        case "invalid_client", "unauthorized_client": return "this app is not authorized for this Sit(x) organization"
        case "invalid_scope": return "requested access is not permitted"
        case "invalid_request", "unsupported_grant_type": return "Sit(x) rejected the request format"
        default: return nil
        }
    }

    /// Extracts a short, human-readable reason from a Sit(x) error body.
    static func serverMessage(from data: Data) -> String? {
        var text: String?
        if let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let code = body["error"] as? String, let friendly = oauthErrorMessage(code) {
            text = friendly
        } else if let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
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

/// A GeoChat or other CoT held by Sit(x) Store and Forward while this device was offline (`GET /api/v1/messages`).
struct SitxStoredMessage: Equatable {
    let id: String
    let payload: String

    /// At most 50 unacknowledged, unexpired messages for the group, oldest first. IDs are restricted to safe
    /// path characters because they are used in the acknowledgement URL.
    static func parse(_ data: Data, flowTag: String, now: Date = Date()) -> [Self] {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ value: Any?) -> Date? {
            guard let text = value as? String else { return nil }
            return formatter.date(from: text) ?? plain.date(from: text)
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let messages = list.compactMap { item -> (Date, Self)? in
            guard let id = item["resource_uid"] as? String, !id.isEmpty, id.count <= 128,
                  id.unicodeScalars.allSatisfy(allowed.contains),
                  let payload = item["payload"] as? String, !payload.isEmpty, payload.utf8.count <= 64_000,
                  item["ack_at"] == nil || item["ack_at"] is NSNull else { return nil }
            if let group = item["tak_group_tag"] as? String, group != flowTag { return nil }
            if let stale = date(item["stale_at"]), stale <= now { return nil }
            var event = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            if event.hasPrefix("<?xml"), let end = event.range(of: "?>") {
                event = String(event[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard event.hasPrefix("<event") else { return nil }
            return (date(item["issued_at"]) ?? .distantPast, Self(id: id, payload: event))
        }
        return messages.sorted { $0.0 < $1.0 }.suffix(50).map(\.1)
    }

    static func listURL(host: String, flowTag: String) -> URL? {
        var components = URLComponents(string: host + "/api/v1/messages")
        components?.queryItems = [URLQueryItem(name: "tak_group_tag", value: flowTag)]
        return components?.url
    }

    static func acknowledgeURL(host: String, id: String) -> URL? {
        URL(string: host + "/api/v1/messages/" + id)
    }
}
