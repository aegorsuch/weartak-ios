import Foundation
import Security

@MainActor
final class TAKChannelClient {
    private let host: String
    private let session: URLSession
    private let trustDelegate: ChannelTrustDelegate

    init(host: String, identity: ClientIdentity, trustedCA: Data?, requestTimeout: TimeInterval = 15) {
        self.host = host
        let delegate = ChannelTrustDelegate(host: host, identity: identity, trustedCA: trustedCA)
        trustDelegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout + 5
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
        let data: Data
        let response: URLResponse
        let endpoint = "Channels API https://\(host):8443\(path)"
        trustDelegate.diagnostics.reset()
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CompanionFailure.message(trustDelegate.diagnostics.message(endpoint: endpoint, error: error))
        }
        guard data.count <= 1_048_576, let http = response as? HTTPURLResponse else {
            throw TAKChannelGroups.ChannelError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CompanionFailure.message("\(endpoint): HTTP \(http.statusCode).")
        }
        return data
    }
}

private final class ChannelTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let host: String
    let identity: ClientIdentity
    let trustedCA: Data?
    let diagnostics = TLSConnectionDiagnostics()

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
        do {
            try CertificateStore.evaluateServerTrust(trust, host: host,
                certificates: identity.certificates, trustedCA: trustedCA)
            completionHandler(.useCredential, URLCredential(trust: trust))
        } catch {
            diagnostics.record(error)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}