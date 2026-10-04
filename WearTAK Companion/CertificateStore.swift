import Foundation
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

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        failure = nil
    }

    func record(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        let underlying = error as NSError
        failure = "\(error.localizedDescription) [\(underlying.domain) \(underlying.code)]"
    }

    func message(endpoint: String, error: Error) -> String {
        lock.lock()
        defer { lock.unlock() }
        let underlying = error as NSError
        return "\(endpoint): \(failure ?? error.localizedDescription) (\(underlying.domain) \(underlying.code))."
    }
}

enum CertificateStore {
    private static let service = "com.aegorsuch.weartak.companion.identities"

    nonisolated static func evaluateServerTrust(_ trust: SecTrust, host: String,
                                    certificates: [SecCertificate], trustedCA: Data?) throws {
        let policyStatus = SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
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
        if !anchors.isEmpty {
            let anchorStatus = SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            // An explicit CA restricts trust; inferred client CAs supplement system roots.
            let rootsStatus = SecTrustSetAnchorCertificatesOnly(trust, trustedCA != nil)
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