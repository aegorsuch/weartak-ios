import Foundation
import Security
import SwiftASN1

enum EnrollmentClient {
    private struct Result: Decodable {
        private struct Key: CodingKey {
            let stringValue: String
            let intValue: Int? = nil

            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        let signedCert: String
        let certificateAuthorities: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            guard let signedCertKey = Key(stringValue: "signedCert") else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid signedCert key."))
            }
            signedCert = try container.decode(String.self, forKey: signedCertKey)
            let authorityKeys = container.allKeys.filter { key in
                guard key.stringValue.hasPrefix("ca") else { return false }
                let suffix = key.stringValue.dropFirst(2)
                return suffix.isEmpty || suffix.utf8.allSatisfy { (48...57).contains($0) }
            }.sorted(by: Self.authorityKeyOrder)
            certificateAuthorities = try authorityKeys.map { try container.decode(String.self, forKey: $0) }
        }

        private static func authorityKeyOrder(_ first: Key, _ second: Key) -> Bool {
            if first.stringValue == "ca" || second.stringValue == "ca" {
                return first.stringValue == "ca" && second.stringValue != "ca"
            }
            let firstNumber = first.stringValue.dropFirst(2).drop(while: { $0 == "0" })
            let secondNumber = second.stringValue.dropFirst(2).drop(while: { $0 == "0" })
            if firstNumber.count != secondNumber.count { return firstNumber.count < secondNumber.count }
            if firstNumber != secondNumber { return firstNumber.lexicographicallyPrecedes(secondNumber) }
            return first.stringValue < second.stringValue
        }
    }

    static func signingChain(from data: Data) throws -> [Data] {
        let result = try JSONDecoder().decode(Result.self, from: data)
        return try ([result.signedCert] + result.certificateAuthorities).map(CertificateStore.decodeCertificate)
    }

    static func enroll(host: String, port: Int, username: String, password: String,
                       deviceID: String, trustedCA: Data?) async throws -> StoredIdentity {
        guard !username.isEmpty, !password.isEmpty, !username.contains(":"), (1...65535).contains(port) else {
            throw CompanionFailure.message("Enter a username, password, and valid enrollment port.")
        }
        let trustDelegate = EnrollmentTrustDelegate(host: host, ca: trustedCA)
        let configuration = TAKHTTPS.configuration(requestTimeout: 30, resourceTimeout: 60)
        let session = URLSession(configuration: configuration, delegate: trustDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var url = URLComponents()
        url.scheme = "https"
        url.host = host
        url.port = port
        url.path = "/Marti/api/tls/config"
        guard let configURL = url.url else { throw CompanionFailure.message("Invalid enrollment URL.") }
        let authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        var request = URLRequest(url: configURL)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let (config, response) = try await session.data(for: request)
        try validate(response, data: config, endpoint: configURL)
        let subject = EnrollmentSubject()
        let parser = XMLParser(data: config)
        parser.shouldResolveExternalEntities = false
        parser.delegate = subject
        guard config.range(of: Data("<!DOCTYPE".utf8)) == nil, parser.parse() else {
            throw CompanionFailure.message("Invalid enrollment configuration XML.")
        }
        let fields = subject.fields
        let (key, csr) = try await Task.detached(priority: .userInitiated) {
            try createRequest(username: username, fields: fields)
        }.value
        try Task.checkCancellation()
        url.path = "/Marti/api/tls/signClient/v2"
        url.queryItems = [URLQueryItem(name: "clientUid", value: deviceID),
                          URLQueryItem(name: "version", value: "WearTAK-Companion-5.8.0")]
        guard let signURL = url.url else { throw CompanionFailure.message("Invalid signing URL.") }
        request = URLRequest(url: signURL)
        request.httpMethod = "POST"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(csr.base64EncodedString().utf8)
        let (data, signingResponse) = try await session.data(for: request)
        try validate(signingResponse, data: data, endpoint: signURL)
        try Task.checkCancellation()
        let chain = try signingChain(from: data)
        return try CertificateStore.enrolled(key: key, chain: chain)
    }

    nonisolated static func createRequest(username: String, fields: [(String, String)]) throws -> (SecKey, Data) {
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 4096] as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(key),
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw CompanionFailure.message("Unable to generate enrollment key.")
        }
        let identifiers: [String: ASN1ObjectIdentifier] = [
            "CN": [2,5,4,3], "C": [2,5,4,6], "L": [2,5,4,7], "ST": [2,5,4,8],
            "O": [2,5,4,10], "OU": [2,5,4,11], "DC": [0,9,2342,19200300,100,1,25]
        ]
        var info = DER.Serializer()
        try info.appendConstructedNode(identifier: .sequence) { writer in
            writer.appendPrimitiveNode(identifier: .integer) { $0.append(0) }
            try writer.appendConstructedNode(identifier: .sequence) { subject in
                for (name, value) in [("CN", username)] + fields.filter({ $0.0.uppercased() != "CN" }) {
                    guard let oid = identifiers[name.uppercased()], !value.isEmpty else {
                        throw CompanionFailure.message("Unsupported enrollment subject field: \(name).")
                    }
                    try subject.appendConstructedNode(identifier: .set) { set in
                        try set.appendConstructedNode(identifier: .sequence) { attribute in
                            try attribute.serialize(oid)
                            let tag: ASN1Identifier = name.uppercased() == "C" ? .printableString : name.uppercased() == "DC" ? .ia5String : .utf8String
                            attribute.appendPrimitiveNode(identifier: tag) { $0.append(contentsOf: value.utf8) }
                        }
                    }
                }
            }
            try writer.appendConstructedNode(identifier: .sequence) { spki in
                try algorithm(&spki, oid: [1,2,840,113549,1,1,1])
                try spki.serialize(ASN1BitString(bytes: Array(publicBytes)[...]))
            }
            writer.appendConstructedNode(identifier: ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific)) { _ in }
        }
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256,
            Data(info.serializedBytes) as CFData, &error) as Data? else {
            throw CompanionFailure.message("Unable to sign enrollment request.")
        }
        var request = DER.Serializer()
        try request.appendConstructedNode(identifier: .sequence) { writer in
            writer.serializeRawBytes(info.serializedBytes)
            try algorithm(&writer, oid: [1,2,840,113549,1,1,11])
            try writer.serialize(ASN1BitString(bytes: Array(signature)[...]))
        }
        return (key, Data(request.serializedBytes))
    }

    nonisolated private static func algorithm(_ writer: inout DER.Serializer, oid: ASN1ObjectIdentifier) throws {
        try writer.appendConstructedNode(identifier: .sequence) { algorithm in
            try algorithm.serialize(oid)
            algorithm.appendPrimitiveNode(identifier: .null) { _ in }
        }
    }

    static func validate(_ response: URLResponse, data: Data, endpoint: URL) throws {
        guard data.count <= 1_048_576, let http = response as? HTTPURLResponse else {
            throw CompanionFailure.message("Invalid enrollment response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let stage = endpoint.path == "/Marti/api/tls/config" ? "configuration" : "certificate signing"
            let address = "\(endpoint.host ?? ""):\(endpoint.port ?? 443)\(endpoint.path)"
            let authorization = http.statusCode == 401
                ? " Enrollment authorization was rejected; compare this account and endpoint with the working client."
                : ""
            throw CompanionFailure.message("Enrollment \(stage) failed: HTTP \(http.statusCode) at \(address).\(authorization)")
        }
    }
}

private final class EnrollmentSubject: NSObject, XMLParserDelegate {
    var fields: [(String, String)] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if elementName == "nameEntry", let name = attributes["name"], let value = attributes["value"] {
            fields.append((name, value))
        }
    }
}

private final class EnrollmentTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let host: String
    let ca: Data?
    init(host: String, ca: Data?) { self.host = host; self.ca = ca }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host, let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        do {
            try CertificateStore.evaluateServerTrust(trust, host: host, certificates: [], trustedCA: ca)
            completionHandler(.useCredential, URLCredential(trust: trust))
        } catch {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}