import Foundation
import Network
import Security
import SwiftASN1

enum CompanionFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

struct StoredIdentity: Codable {
    var p12: Data?
    var passphrase: String?
    var keyTag: Data?
    let chain: [Data]
}

struct ClientIdentity {
    let identity: SecIdentity
    let certificates: [SecCertificate]
    let expires: Date
}

nonisolated final class TLSConnectionDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: String?
    private var hostnameMismatch = false

    var hasHostnameMismatch: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hostnameMismatch
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        failure = nil
        hostnameMismatch = false
    }

    func record(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        let underlying = error as NSError
        hostnameMismatch = underlying.domain == NSOSStatusErrorDomain && underlying.code == -67602
        failure = "\(error.localizedDescription) [\(underlying.domain) \(underlying.code)]"
    }

    func message(endpoint: String, error: Error) -> String {
        lock.lock()
        defer { lock.unlock() }
        let underlying = error as NSError
        return "\(endpoint): \(failure ?? error.localizedDescription) (\(underlying.domain) \(underlying.code))."
    }
}

struct TLSHostnameMismatch: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

enum CertificateStore {
    private static let service = "com.aegorsuch.weartak.companion.identities"

    nonisolated static func evaluateServerTrust(_ trust: SecTrust, host: String,
                                    certificates: [SecCertificate], trustedCA: Data?) throws {
        try evaluateTrust(trust, host: host, certificates: certificates, trustedCA: trustedCA)
    }

    nonisolated static func inspectServerTrust(_ trust: SecTrust, certificates: [SecCertificate],
                                              trustedCA: Data?, automatic: Bool = false) throws -> [String] {
        if automatic {
            guard let chain = SecTrustCopyCertificateChain(trust) else {
                throw CompanionFailure.message("The server did not provide a certificate chain.")
            }
            var publicTrust: SecTrust?
            guard SecTrustCreateWithCertificates(chain, SecPolicyCreateSSL(true, nil), &publicTrust) == errSecSuccess,
                  let publicTrust else { throw CompanionFailure.message("Unable to check public CA trust.") }
            SecTrustSetNetworkFetchAllowed(publicTrust, false)
            if SecTrustEvaluateWithError(publicTrust, nil) {
                throw CompanionFailure.message("Automatic legacy identity discovery is unavailable for public-CA certificates. Ask the administrator for a certificate matching the server hostname.")
            }
        }
        try evaluateTrust(trust, host: nil, certificates: certificates, trustedCA: trustedCA,
                          restrictToProvidedCA: automatic)
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            throw CompanionFailure.message("The server did not provide a certificate.")
        }
        let names = try dnsSubjectAlternativeNames(leaf)
        guard !names.isEmpty else {
            throw CompanionFailure.message("The server certificate has no supported exact DNS SAN names. Ask the administrator for a certificate with a DNS SAN; names are not guessed from its Common Name.")
        }
        return names
    }

    nonisolated static func automaticTLSName(_ names: [String]) throws -> String {
        guard names.count == 1, let name = names.first,
              let validated = try CompanionServer.validatedStreamTLSName(name), name == validated else {
            throw CompanionFailure.message("Automatic certificate discovery requires one exact DNS SAN. Ask the administrator for a certificate matching the server hostname when multiple or unsupported names are present.")
        }
        return validated
    }

    nonisolated private static func evaluateTrust(_ trust: SecTrust, host: String?,
                                                  certificates: [SecCertificate], trustedCA: Data?,
                                                  restrictToProvidedCA: Bool = false) throws {
        let policyStatus = SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host.map { $0 as CFString }))
        guard policyStatus == errSecSuccess else {
            throw CompanionFailure.message("Unable to configure TLS hostname validation (\(policyStatus)).")
        }
        let anchors: [SecCertificate]
        if let trustedCA {
            guard let ca = SecCertificateCreateWithData(nil, trustedCA as CFData) else {
                throw CompanionFailure.message("The configured server CA is not a valid DER certificate.")
            }
            anchors = [ca]
        } else {
            anchors = Array(certificates.dropFirst())
        }
        if restrictToProvidedCA && anchors.isEmpty {
            throw CompanionFailure.message("Automatic certificate discovery requires the server's enrollment/import CA chain.")
        }
        if !anchors.isEmpty {
            let anchorStatus = SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            // An explicit CA restricts trust; inferred client CAs supplement system roots.
            let rootsStatus = SecTrustSetAnchorCertificatesOnly(trust, trustedCA != nil || restrictToProvidedCA)
            guard anchorStatus == errSecSuccess, rootsStatus == errSecSuccess else {
                throw CompanionFailure.message("Unable to configure TLS trust anchors (\(anchorStatus), \(rootsStatus)).")
            }
        }
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            if let error { throw error as Error }
            throw CompanionFailure.message("The server certificate failed hostname or certificate-chain validation.")
        }
    }

    nonisolated static func dnsSubjectAlternativeNames(_ certificate: SecCertificate) throws -> [String] {
        let root = try DER.parse(Array(SecCertificateCopyData(certificate) as Data))
        guard case .constructed(let children) = root.content, let tbs = Array(children).first,
              case .constructed(let fields) = tbs.content else {
            throw CompanionFailure.message("Invalid X.509 certificate.")
        }
        guard let extensions = fields.first(where: {
            $0.identifier == ASN1Identifier(tagWithNumber: 3, tagClass: .contextSpecific)
        }) else { return [] }
        guard case .constructed(let wrapper) = extensions.content, let sequence = Array(wrapper).first,
              case .constructed(let entries) = sequence.content else {
            throw CompanionFailure.message("Invalid certificate extensions.")
        }
        for entry in entries {
            guard case .constructed(let values) = entry.content else {
                throw CompanionFailure.message("Invalid certificate extension.")
            }
            let nodes = Array(values)
            guard let oid = nodes.first else {
                throw CompanionFailure.message("Missing certificate extension identifier.")
            }
            guard try ASN1ObjectIdentifier(derEncoded: oid) == [2, 5, 29, 17] else { continue }
            guard let value = nodes.last else {
                throw CompanionFailure.message("Missing certificate SAN extension.")
            }
            let namesNode = try DER.parse(ASN1OctetString(derEncoded: value).bytes)
            guard namesNode.identifier == .sequence, case .constructed(let names) = namesNode.content else {
                throw CompanionFailure.message("Invalid certificate SAN extension.")
            }
            var result = Set<String>()
            for name in names where name.identifier == ASN1Identifier(tagWithNumber: 2, tagClass: .contextSpecific) {
                guard case .primitive(let bytes) = name.content, let text = String(bytes: bytes, encoding: .ascii) else {
                    throw CompanionFailure.message("Invalid certificate DNS SAN.")
                }
                // Wildcard SANs cannot be used as an exact, approved TLS-name override.
                if text.contains("*") { continue }
                if let validated = try CompanionServer.validatedStreamTLSName(text) { result.insert(validated) }
            }
            return result.sorted()
        }
        return []
    }

    static func read(endpoint: String) throws -> StoredIdentity? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword, kSecAttrService: service,
            kSecAttrAccount: endpoint, kSecReturnData: true
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CompanionFailure.message("Keychain read failed (\(status)).")
        }

        return try JSONDecoder().decode(StoredIdentity.self, from: data)
    }

    static func save(_ stored: StoredIdentity, endpoint: String) throws {
        let previous = try read(endpoint: endpoint)
        let data = try JSONEncoder().encode(stored)
        let query = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: endpoint] as CFDictionary
        var status = SecItemUpdate(query, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd([
                kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                kSecAttrAccount: endpoint, kSecValueData: data,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ] as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CompanionFailure.message("Keychain save failed (\(status)).") }
        if previous?.keyTag != stored.keyTag, let tag = previous?.keyTag {
            SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag] as CFDictionary)
        }
    }

    static func remove(endpoint: String) throws {
        if let stored = try read(endpoint: endpoint), let tag = stored.keyTag {
            SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag] as CFDictionary)
        }
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: endpoint] as CFDictionary)
    }

    static func discardUncommitted(_ stored: StoredIdentity) {
        if let tag = stored.keyTag {
            SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag] as CFDictionary)
        }
    }

    private static func unpack(_ data: Data, password: String) throws -> (SecIdentity, [SecCertificate]) {
        guard data.count <= 1_048_576 else { throw CompanionFailure.message("Certificate file exceeds 1 MB.") }
        var result: CFArray?
        var options: [CFString: Any] = [kSecImportExportPassphrase: password]
        #if os(macOS)
        options[kSecImportToMemoryOnly] = true
        #endif
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &result)
        guard status == errSecSuccess, let item = (result as? [[String: Any]])?.first,
              let raw = item[kSecImportItemIdentity as String], CFGetTypeID(raw as CFTypeRef) == SecIdentityGetTypeID() else {
            throw CompanionFailure.message("Cannot open .p12. Check its password and client private key (\(status)).")
        }
        let identity = raw as! SecIdentity
        var leaf: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &leaf) == errSecSuccess, let leaf else {
            throw CompanionFailure.message("The .p12 has no client certificate.")
        }
        let chain = item[kSecImportItemCertChain as String] as? [SecCertificate] ?? [leaf]
        return (identity, chain)
    }

    static func importP12(_ data: Data, password: String) throws -> StoredIdentity {
        let (identity, chain) = try unpack(data, password: password)
        guard let leaf = chain.first else { throw CompanionFailure.message("Missing certificate chain.") }
        var key: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess, let key else {
            throw CompanionFailure.message("The .p12 must include a private key.")
        }
        try verify(key: key, leaf: leaf)
        _ = try expiry(of: leaf)
        return StoredIdentity(p12: data, passphrase: password, chain: chain.map { SecCertificateCopyData($0) as Data })
    }

    static func resolve(_ stored: StoredIdentity) throws -> ClientIdentity {
        let certificates = try stored.chain.map { data -> SecCertificate in
            guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
                throw CompanionFailure.message("Invalid stored certificate.")
            }
            return certificate
        }
        guard let leaf = certificates.first else { throw CompanionFailure.message("Missing client certificate.") }
        let identity: SecIdentity
        if let p12 = stored.p12 {
            identity = try unpack(p12, password: stored.passphrase ?? "").0
        } else {
            var result: CFTypeRef?
            let status = SecItemCopyMatching([
                kSecClass: kSecClassIdentity, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll
            ] as CFDictionary, &result)
            let candidates = result as? [SecIdentity] ?? []
            guard status == errSecSuccess, let matching = candidates.first(where: { candidate in
                var certificate: SecCertificate?
                return SecIdentityCopyCertificate(candidate, &certificate) == errSecSuccess &&
                    certificate.map { SecCertificateCopyData($0) as Data == stored.chain[0] } == true
            }) else { throw CompanionFailure.message("Enrolled private key is unavailable; enroll again.") }
            identity = matching
        }
        return ClientIdentity(identity: identity, certificates: certificates, expires: try expiry(of: leaf))
    }

    static func enrolled(key: SecKey, chain: [Data]) throws -> StoredIdentity {
        guard let data = chain.first, let leaf = SecCertificateCreateWithData(nil, data as CFData) else {
            throw CompanionFailure.message("Enrollment returned an invalid certificate.")
        }
        try verify(key: key, leaf: leaf)
        _ = try expiry(of: leaf)
        let tag = Data((service + "." + UUID().uuidString).utf8)
        let status = SecItemAdd([
            kSecClass: kSecClassKey, kSecValueRef: key, kSecAttrApplicationTag: tag,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw CompanionFailure.message("Private-key storage failed (\(status)).") }
        let certStatus = SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: leaf] as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag] as CFDictionary)
            throw CompanionFailure.message("Certificate storage failed (\(certStatus)).")
        }
        return StoredIdentity(keyTag: tag, chain: chain)
    }

    static func verify(key: SecKey, leaf: SecCertificate) throws {
        guard let publicKey = SecCertificateCopyKey(leaf) else { throw CompanionFailure.message("Missing public key.") }
        let algorithm: SecKeyAlgorithm = SecKeyIsAlgorithmSupported(key, .sign, .rsaSignatureMessagePKCS1v15SHA256)
            ? .rsaSignatureMessagePKCS1v15SHA256 : .ecdsaSignatureMessageX962SHA256
        let challenge = Data(UUID().uuidString.utf8) as CFData
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(key, algorithm, challenge, &error),
              SecKeyVerifySignature(publicKey, algorithm, challenge, signature, &error) else {
            throw CompanionFailure.message("Certificate and private key do not match.")
        }
    }

    static func expiry(of certificate: SecCertificate, now: Date = Date()) throws -> Date {
        let root = try DER.parse(Array(SecCertificateCopyData(certificate) as Data))
        guard case .constructed(let children) = root.content, let tbs = Array(children).first,
              case .constructed(let body) = tbs.content else { throw CompanionFailure.message("Invalid X.509 certificate.") }
        let fields = Array(body)
        let offset = fields.first?.identifier == ASN1Identifier(tagWithNumber: 0, tagClass: .contextSpecific) ? 1 : 0
        guard fields.count > offset + 3, case .constructed(let validity) = fields[offset + 3].content else {
            throw CompanionFailure.message("Missing certificate validity.")
        }
        let dates = try Array(validity).map { node -> Date in
            guard case .primitive(let bytes) = node.content, var text = String(bytes: bytes, encoding: .ascii) else {
                throw CompanionFailure.message("Invalid certificate date.")
            }
            if node.identifier == .utcTime {
                guard let year = Int(text.prefix(2)) else { throw CompanionFailure.message("Invalid certificate year.") }
                text = (year >= 50 ? "19" : "20") + text
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMddHHmmss'Z'"
            guard let date = formatter.date(from: text) else { throw CompanionFailure.message("Unsupported certificate date.") }
            return date
        }
        guard dates.count == 2, dates[0] <= now, now < dates[1] else {
            throw CompanionFailure.message("Certificate expired or not yet valid. Check the phone clock.")
        }
        return dates[1]
    }

    static func decodeCertificate(_ text: String) throws -> Data {
        let encoded = text.replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "").filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: encoded), SecCertificateCreateWithData(nil, data as CFData) != nil else {
            throw CompanionFailure.message("Invalid certificate data.")
        }
        return data
    }
}

@MainActor
final class ServerCertificateInspection {
    private let queue = DispatchQueue(label: "WearTAK.CertificateInspection")
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<[String], Error>?
    private var timeout: Task<Void, Never>?
    private var inspectionID: UUID?

    func inspect(host: String, port: Int, certificates: [SecCertificate], trustedCA: Data?,
                 automatic: Bool = false) async throws -> [String] {
        guard (1...65535).contains(port), let networkPort = NWEndpoint.Port(rawValue: UInt16(port)),
              !host.isEmpty else { throw CompanionFailure.message("Invalid certificate inspection endpoint.") }
        guard connection == nil else { throw CompanionFailure.message("Certificate inspection is already running.") }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.inspectionID = id
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
                sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
                sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, securityTrust, complete in
                    let trust = sec_trust_copy_ref(securityTrust).takeRetainedValue()
                    let result = Result { try CertificateStore.inspectServerTrust(trust, certificates: certificates,
                                                                                 trustedCA: trustedCA, automatic: automatic) }
                    Task { @MainActor in
                        // Inspection never completes TLS or sends a client identity or application data.
                        complete(false)
                        self?.finish(result, id: id)
                    }
                }, queue)
                let socket = NWConnection(host: .init(host), port: networkPort,
                                          using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
                connection = socket
                socket.stateUpdateHandler = { [weak self] state in
                    if case .failed(let error) = state {
                        Task { @MainActor in self?.finish(.failure(error), id: id) }
                    } else if case .waiting(let error) = state {
                        Task { @MainActor in self?.finish(.failure(error), id: id) }
                    }
                }
                socket.start(queue: queue)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    self?.finish(.failure(CompanionFailure.message("Certificate inspection timed out at \(host):\(port).")), id: id)
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError()), id: id) }
        }
    }

    private func finish(_ result: Result<[String], Error>, id: UUID) {
        guard inspectionID == id, let continuation else { return }
        self.continuation = nil
        inspectionID = nil
        timeout?.cancel()
        timeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        continuation.resume(with: result)
    }
}