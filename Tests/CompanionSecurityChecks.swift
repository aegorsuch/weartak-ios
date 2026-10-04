import Foundation
import Security

@main
struct CompanionSecurityChecks {
    static func main() throws {
        let configuration = TAKHTTPS.configuration(requestTimeout: 15, resourceTimeout: 20)
        precondition(configuration.tlsMinimumSupportedProtocolVersion == .TLSv12)
        precondition(configuration.timeoutIntervalForRequest == 15 && configuration.timeoutIntervalForResource == 20)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("weartak-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (key, csr) = try EnrollmentClient.createRequest(username: "operator", fields: [("O", "Test, Team + One"), ("C", "US")])
        try csr.write(to: directory.appendingPathComponent("request.der"))
        try openssl(["req", "-inform", "DER", "-verify", "-noout", "-in", "request.der"], in: directory)
        try openssl(["req", "-inform", "DER", "-in", "request.der", "-out", "request.pem"], in: directory)
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "1", "-subj", "/CN=WearTAK Fixture CA"], in: directory)
        try openssl(["x509", "-req", "-in", "request.pem", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", "client.pem", "-days", "1"], in: directory)
        let leafData = try CertificateStore.decodeCertificate(String(contentsOf: directory.appendingPathComponent("client.pem"), encoding: .utf8))
        guard let leaf = SecCertificateCreateWithData(nil, leafData as CFData) else { fatalError("Invalid fixture certificate") }
        try CertificateStore.verify(key: key, leaf: leaf)
        let expiry = try CertificateStore.expiry(of: leaf)
        precondition(expiry > Date())
        do {
            _ = try CertificateStore.expiry(of: leaf, now: expiry.addingTimeInterval(1))
            fatalError("Expired certificate accepted")
        } catch CompanionFailure.message {}
        let (wrongKey, _) = try EnrollmentClient.createRequest(username: "other", fields: [])
        do {
            try CertificateStore.verify(key: wrongKey, leaf: leaf)
            fatalError("Mismatched key accepted")
        } catch CompanionFailure.message {}
        var error: Unmanaged<CFError>?
        guard let privateData = SecKeyCopyExternalRepresentation(key, &error) as Data? else { fatalError("Fixture private key export failed") }
        try privateData.write(to: directory.appendingPathComponent("client.key.der"))
        try openssl(["rsa", "-inform", "DER", "-in", "client.key.der", "-out", "client.key"], in: directory)
        try openssl(["pkcs12", "-export", "-inkey", "client.key", "-in", "client.pem", "-certfile", "ca.pem", "-out", "client.p12", "-passout", "pass:fixture-only"], in: directory)
        let p12 = try Data(contentsOf: directory.appendingPathComponent("client.p12"))
        let imported = try CertificateStore.importP12(p12, password: "fixture-only")
        let resolved = try CertificateStore.resolve(imported)
        precondition(resolved.expires > Date() && !resolved.certificates.isEmpty)
        do {
            _ = try CertificateStore.importP12(p12, password: "wrong-fixture-password")
            fatalError("Wrong .p12 password accepted")
        } catch CompanionFailure.message {}
        try checkServerTrust(in: directory, client: leaf)
        let diagnostics = TLSConnectionDiagnostics()
        diagnostics.record(CompanionFailure.message("Hostname mismatch"))
        let networkError = NSError(domain: NSURLErrorDomain, code: -1200,
                                   userInfo: [NSLocalizedDescriptionKey: "TLS handshake failed"])
        let message = diagnostics.message(endpoint: "Channels API https://fixture.example:8443", error: networkError)
        precondition(message.contains("fixture.example:8443") && message.contains("Hostname mismatch") &&
                     message.contains("NSURLErrorDomain -1200"))
        diagnostics.reset()
        precondition(!diagnostics.message(endpoint: "Channels API", error: networkError).contains("Hostname mismatch"))
        print("PASS: CSR, identity, expiry, server trust, hostname rejection, explicit CA and TLS diagnostics checks")
    }

    static func checkServerTrust(in directory: URL, client: SecCertificate) throws {
        let extensions = """
        basicConstraints=critical,CA:FALSE
        keyUsage=critical,digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        subjectAltName=DNS:fixture.example
        """
        try Data(extensions.utf8).write(to: directory.appendingPathComponent("server.ext"))
        try openssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "server.key",
                     "-out", "server.csr", "-subj", "/CN=fixture.example"], in: directory)
        try openssl(["x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key",
                     "-CAcreateserial", "-out", "server.pem", "-days", "1", "-extfile", "server.ext"], in: directory)
        try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "other-ca.key",
                     "-out", "other-ca.pem", "-days", "1", "-subj", "/CN=Unrelated Fixture CA"], in: directory)
        func certificate(_ name: String) throws -> SecCertificate {
            let data = try CertificateStore.decodeCertificate(
                String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8))
            guard let certificate = SecCertificateCreateWithData(nil, data as CFData) else {
                throw CompanionFailure.message("Invalid TLS fixture certificate.")
            }
            return certificate
        }
        let server = try certificate("server.pem")
        let ca = try certificate("ca.pem")
        let otherCA = try certificate("other-ca.pem")
        func evaluate(host: String = "fixture.example", chain: [SecCertificate], date: Date = Date(),
                      explicitCA: Data? = nil) throws {
            var trust: SecTrust?
            let status = SecTrustCreateWithCertificates([server, ca] as CFArray,
                                                       SecPolicyCreateSSL(true, nil), &trust)
            guard status == errSecSuccess, let trust else {
                throw CompanionFailure.message("Unable to create fixture trust (\(status)).")
            }
            SecTrustSetNetworkFetchAllowed(trust, false)
            SecTrustSetVerifyDate(trust, date as CFDate)
            try CertificateStore.evaluateServerTrust(trust, host: host, certificates: chain, trustedCA: explicitCA)
        }
        let caData = SecCertificateCopyData(ca) as Data
        try evaluate(chain: [client, ca])
        try evaluate(chain: [client], explicitCA: caData)
        do {
            try evaluate(chain: [client, ca], date: Date().addingTimeInterval(3 * 86_400))
            fatalError("Expired TLS server certificate accepted")
        } catch {}
        do {
            try evaluate(host: "wrong.example", chain: [client, ca])
            fatalError("TLS hostname mismatch accepted")
        } catch {}
        do {
            try evaluate(chain: [client])
            fatalError("Untrusted private server CA accepted")
        } catch {}
        do {
            try evaluate(chain: [client, ca], explicitCA: SecCertificateCopyData(otherCA) as Data)
            fatalError("Explicit server CA restriction bypassed")
        } catch {}
        do {
            try evaluate(chain: [client, ca], explicitCA: Data("not a certificate".utf8))
            fatalError("Invalid configured CA silently ignored")
        } catch CompanionFailure.message(let message) {
            precondition(message.contains("DER certificate"))
        }
    }

    static func openssl(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CompanionFailure.message("Fixture OpenSSL \(arguments.prefix(2).joined(separator: " ")) failed: " + String(decoding: data, as: UTF8.self))
        }
    }
}