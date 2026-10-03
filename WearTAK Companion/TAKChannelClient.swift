import Foundation
import Security

@MainActor
final class TAKChannelClient {
    private let host: String
    private let session: URLSession

    init(host: String, identity: ClientIdentity, trustedCA: Data?) {
        self.host = host
        let delegate = ChannelTrustDelegate(host: host, identity: identity, trustedCA: trustedCA)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    func cancel() { session.invalidateAndCancel() }

    func load(checkSupport: Bool, sendLatestSA: Bool) async throws -> TAKChannelGroups {
        if checkSupport {
            let data = try await execute(path: "/Marti/api/groups/groupCacheEnabled")
            guard try TAKChannelGroups.support(data) else { throw TAKChannelGroups.ChannelError.unsupported }
        }
        var query = [URLQueryItem(name: "useCache", value: "true")]
        if sendLatestSA { query.append(URLQueryItem(name: "sendLatestSA", value: "true")) }
        return try TAKChannelGroups.parse(await execute(path: "/Marti/api/groups/all", query: query))
    }

    func update(bitPosition: Int, active: Bool, clientUID: String) async throws -> TAKChannelGroups {
        let current = try await load(checkSupport: false, sendLatestSA: false)
        let desired = try current.changing(bitPosition: bitPosition, active: active)
        _ = try await execute(path: "/Marti/api/groups/active", method: "PUT",
                              query: [URLQueryItem(name: "clientUid", value: clientUID)], body: desired.encodedPayload())
        return desired
    }

    private func execute(path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = 8443
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CompanionFailure.message("Invalid channel server URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard data.count <= 1_048_576, let http = response as? HTTPURLResponse else {
            throw TAKChannelGroups.ChannelError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CompanionFailure.message("Channel request failed: HTTP \(http.statusCode).")
        }
        return data
    }
}

private final class ChannelTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let host: String
    let identity: ClientIdentity
    let trustedCA: Data?

    init(host: String, identity: ClientIdentity, trustedCA: Data?) {
        self.host = host
        self.identity = identity
        self.trustedCA = trustedCA
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.host.caseInsensitiveCompare(host) == .orderedSame else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            completionHandler(.useCredential, URLCredential(identity: identity.identity,
                certificates: Array(identity.certificates.dropFirst()), persistence: .forSession))
            return
        }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        let anchors: [SecCertificate]
        if let trustedCA, let ca = SecCertificateCreateWithData(nil, trustedCA as CFData) { anchors = [ca] }
        else { anchors = Array(identity.certificates.dropFirst()) }
        if !anchors.isEmpty {
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}