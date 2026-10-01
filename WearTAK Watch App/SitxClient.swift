import Combine
import Foundation
import Security

@MainActor
final class SitxClient: ObservableObject {
    private enum State {
        static let unconfigured = "Not connected"
        static let requestingCode = "Requesting device code"
        static let awaitingAuthorization = "Waiting for authorization"
        static let refreshing = "Refreshing token"
        static let checking = "Checking account"
        static let connected = "Connected"
        static let expired = "Code expired; retry"
    }

    private static let clientID = "D4RTE81TJjccxlc8LPD7QQ"
    private static let keychainService = "com.aegorsuch.weartak.sitx"
    private let settings: AppSettings
    private let session: URLSession
    private var accessToken: String?
    private var refreshToken: String?
    private var deviceCode: String?
    private var expiresAt: Date?
    private var pollInterval: TimeInterval = 5
    private var pairingTask: Task<Void, Never>?
    private var tokenHost: String?

    @Published private(set) var authorizationCode = ""
    @Published private(set) var verificationURL = ""
    @Published private(set) var status = State.unconfigured

    var menuLabel: String {
        if status == State.connected || status == "Authorized; select Connect / Pair to verify" {
            return "Sit(x) Enabled"
        }
        let lowercasedStatus = status.lowercased()
        if lowercasedStatus.contains("error") || lowercasedStatus.contains("failed") ||
            lowercasedStatus.contains("http ") || lowercasedStatus.contains("expired") {
            return "Sit(x) Error"
        }
        return "Sit(x) Disabled"
    }

    init(settings: AppSettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
        accessToken = Self.readToken(account: "access")
        refreshToken = Self.readToken(account: "refresh")
        tokenHost = Self.readToken(account: "host")
        if accessToken != nil || refreshToken != nil {
            status = "Authorized; select Connect / Pair to verify"
        }
    }

    func connect() {
        pairingTask?.cancel()
        pairingTask = Task { await beginPairing() }
    }

    func refreshAuthorizationCode() {
        pairingTask?.cancel()
        pairingTask = Task { await beginPairing() }
    }

    func forgetAuthorization() {
        pairingTask?.cancel()
        pairingTask = nil
        clearTokens()
        authorizationCode = ""
        verificationURL = ""
        status = State.unconfigured
    }

    private func beginPairing() async {
        guard let host = Self.normalizedHost(settings.sitxApiHost) else {
            status = settings.sitxApiHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Enter Sit(x) API host"
                : "Enter a valid HTTPS host"
            return
        }
        settings.sitxApiHost = host
        if tokenHost != host {
            clearTokens()
        }
        if let refreshToken {
            await refreshAccessToken(refreshToken, host: host)
        } else {
            await requestDeviceCode(host: host)
        }
    }

    private func requestDeviceCode(host: String) async {
        status = State.requestingCode
        do {
            let deviceID = Self.deviceID()
            let scope = "role:org_user callsign:WEARTAK-\(deviceID.prefix(8)) device_name:\(settings.watchLabel) device_id:\(deviceID)"
            let response = try await postJSON(
                host: host,
                path: "/api/v1/device/authorization/code",
                body: ["scope": scope, "client_id": Self.clientID]
            )
            guard let code = response["device_code"] as? String,
                  let userCode = response["user_code"] as? String else {
                throw SitxError.invalidResponse
            }
            deviceCode = code
            authorizationCode = userCode
            verificationURL = response["verification_uri"] as? String
                ?? response["verification_url"] as? String
                ?? ""
            pollInterval = max(1, response["interval"] as? Double ?? 5)
            expiresAt = Date().addingTimeInterval(response["expires_in"] as? Double ?? 600)
            status = State.awaitingAuthorization
            await pollForAuthorization(host: host)
        } catch is CancellationError {
            return
        } catch {
            status = Self.errorSummary(error, context: "Sit(x) device authorization")
        }
    }

    private func pollForAuthorization(host: String) async {
        while !Task.isCancelled, let deviceCode, let expiresAt {
            guard Date() < expiresAt else {
                status = State.expired
                self.deviceCode = nil
                return
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
                let response = try await postForm(
                    host: host,
                    path: "/api/v1/device/authorization/token",
                    fields: [
                        "client_id": Self.clientID,
                        "device_code": deviceCode,
                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
                    ]
                )
                guard let token = response["access_token"] as? String else {
                    throw SitxError.invalidResponse
                }
                accessToken = token
                refreshToken = response["refresh_token"] as? String
                try Self.saveToken(token, account: "access")
                if let refreshToken { try Self.saveToken(refreshToken, account: "refresh") }
                try Self.saveToken(host, account: "host")
                tokenHost = host
                authorizationCode = ""
                verificationURL = ""
                self.deviceCode = nil
                await verifyAccount(host: host)
                return
            } catch is CancellationError {
                return
            } catch let error as SitxError where error == .authorizationPending {
                continue
            } catch let error as SitxError where error == .slowDown {
                pollInterval += 5
            } catch {
                status = Self.errorSummary(error, context: "Sit(x) token exchange")
                return
            }
        }
    }

    private func refreshAccessToken(_ refreshToken: String, host: String) async {
        status = State.refreshing
        do {
            let response = try await postForm(
                host: host,
                path: "/api/v1/refresh/token",
                fields: [
                    "client_id": Self.clientID,
                    "refresh_token": refreshToken,
                    "grant_type": "refresh_token"
                ]
            )
            guard let token = response["access_token"] as? String else {
                clearTokens()
                await requestDeviceCode(host: host)
                return
            }
            accessToken = token
            self.refreshToken = response["refresh_token"] as? String ?? refreshToken
            try Self.saveToken(token, account: "access")
            if let newRefreshToken = self.refreshToken { try Self.saveToken(newRefreshToken, account: "refresh") }
            try Self.saveToken(host, account: "host")
            tokenHost = host
            await verifyAccount(host: host)
        } catch {
            clearTokens()
            await requestDeviceCode(host: host)
        }
    }

    private func verifyAccount(host: String) async {
        status = State.checking
        do {
            var request = URLRequest(url: URL(string: host + "/api/v1/myinfo")!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(accessToken ?? "")", forHTTPHeaderField: "Authorization")
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                status = "Authorized; profile check returned no HTTP response"
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                status = "Authorized; profile check HTTP \(http.statusCode)"
                return
            }
            status = State.connected
        } catch {
            status = "Authorized; " + Self.errorSummary(error, context: "profile check")
        }
    }

    private static func errorSummary(_ error: Error, context: String) -> String {
        if let sitxError = error as? SitxError {
            return "\(context) failed: \(sitxError.localizedDescription)"
        }
        let nsError = error as NSError
        if let urlError = error as? URLError {
            return "\(context) network error \(urlError.code.rawValue)"
        }
        return "\(context) failed (\(nsError.domain) \(nsError.code))"
    }

    private func postJSON(host: String, path: String, body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: host + path)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func postForm(host: String, path: String, fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: host + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SitxError.invalidResponse }
        if http.statusCode == 400 {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch body?["error"] as? String {
            case "authorization_pending": throw SitxError.authorizationPending
            case "slow_down": throw SitxError.slowDown
            case "expired_token": throw SitxError.authorizationExpired
            default: break
            }
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SitxError.httpStatus(http.statusCode)
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func clearTokens() {
        accessToken = nil
        refreshToken = nil
        tokenHost = nil
        for account in ["access", "refresh", "host"] { Self.deleteToken(account: account) }
    }

    private static func deviceID() -> String {
        let key = "WearTAK.sitxDeviceID"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    private static func normalizedHost(_ value: String) -> String? {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return nil }
        if host.hasPrefix("http://") { host = "https://" + host.dropFirst(7) }
        else if !host.hasPrefix("https://") { host = "https://" + host }
        while host.hasSuffix("/") { host.removeLast() }
        guard let components = URLComponents(string: host), components.scheme == "https",
              components.host != nil, components.query == nil, components.fragment == nil else { return nil }
        return host
    }

    private static func readToken(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func saveToken(_ value: String, account: String) throws {
        deleteToken(account: account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw SitxError.keychain(status) }
    }

    private static func deleteToken(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private enum SitxError: Error, Equatable {
    case authorizationPending
    case slowDown
    case authorizationExpired
    case accountVerificationFailed
    case invalidResponse
    case httpStatus(Int)
    case keychain(OSStatus)

    var localizedDescription: String {
        switch self {
        case .authorizationPending: return "Waiting for authorization"
        case .slowDown: return "Authorization server requested slower polling"
        case .authorizationExpired: return "Code expired; retry"
        case .accountVerificationFailed: return "Account verification failed"
        case .invalidResponse: return "Invalid Sit(x) response"
        case .httpStatus(let code): return "Sit(x) HTTP \(code)"
        case .keychain(let status): return "Secure token storage failed (\(status))"
        }
    }
}
