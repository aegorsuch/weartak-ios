import Foundation
import Network
import Security

@main
struct CompanionSecurityChecks {
    @MainActor
    static func main() async throws {
        let configuration = TAKHTTPS.configuration(requestTimeout: 15, resourceTimeout: 20)
        precondition(configuration.tlsMinimumSupportedProtocolVersion == .TLSv12)
        precondition(configuration.timeoutIntervalForRequest == 15 && configuration.timeoutIntervalForResource == 20)
        for path in ["/Marti/api/tls/config", "/Marti/api/tls/signClient/v2"] {
            let endpoint = URL(string: "https://fixture.example:8446\(path)?clientUid=private-device")!
            let response = HTTPURLResponse(url: endpoint, statusCode: 401, httpVersion: nil, headerFields: nil)!
            do {
                try EnrollmentClient.validate(response, data: Data(), endpoint: endpoint)
                fatalError("Unauthorized enrollment accepted")
            } catch CompanionFailure.message(let message) {
                precondition(message.contains("HTTP 401") && message.contains("fixture.example:8446\(path)") &&
                             message.contains(path.hasSuffix("config") ? "configuration" : "certificate signing") &&
                             !message.contains("private-device"))
            }
            let success = HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
            try EnrollmentClient.validate(success, data: Data(), endpoint: endpoint)
        }
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
        try checkEnrollmentCAResponses(in: directory)
        try await checkCertificateInspection(in: directory)
        let diagnostics = TLSConnectionDiagnostics()
        diagnostics.record(CompanionFailure.message("Hostname mismatch"))
        let networkError = NSError(domain: NSURLErrorDomain, code: -1200,
                                   userInfo: [NSLocalizedDescriptionKey: "TLS handshake failed"])
        let message = diagnostics.message(endpoint: "Channels API https://fixture.example:8443", error: networkError)
        precondition(message.contains("fixture.example:8443") && message.contains("Hostname mismatch") &&
                     message.contains("NSURLErrorDomain -1200"))
        diagnostics.reset()
        precondition(!diagnostics.message(endpoint: "Channels API", error: networkError).contains("Hostname mismatch"))
        diagnostics.record(NSError(domain: NSOSStatusErrorDomain, code: -67602))
        precondition(diagnostics.hasHostnameMismatch)
        diagnostics.reset()
        precondition(!diagnostics.hasHostnameMismatch)
        let automaticName = try CertificateStore.automaticTLSName(["takserver2"])
        precondition(automaticName == "takserver2")
        for candidates in [[], ["first", "second"], ["*.example.net"], ["https://takserver2"]] {
            do {
                _ = try CertificateStore.automaticTLSName(candidates)
                fatalError("Automatic discovery selected an ambiguous or invalid identity")
            } catch {}
        }
        diagnostics.record(NSError(domain: NSOSStatusErrorDomain, code: -67843))
        precondition(!diagnostics.hasHostnameMismatch)
        print("PASS: CSR, identity, expiry, server trust, hostname rejection, explicit CA and TLS diagnostics checks")
    }

    static func checkEnrollmentCAResponses(in directory: URL) throws {
        let leaf = try String(contentsOf: directory.appendingPathComponent("client.pem"), encoding: .utf8)
        let ca = try String(contentsOf: directory.appendingPathComponent("ca.pem"), encoding: .utf8)
        let otherCA = try String(contentsOf: directory.appendingPathComponent("other-ca.pem"), encoding: .utf8)
        func chain(_ fields: [String: String]) throws -> [Data] {
            try EnrollmentClient.signingChain(from: JSONSerialization.data(withJSONObject: fields))
        }
        let leafData = try CertificateStore.decodeCertificate(leaf)
        let caData = try CertificateStore.decodeCertificate(ca)
        let otherCAData = try CertificateStore.decodeCertificate(otherCA)

        let openTAKChain = try chain(["signedCert": leaf, "ca": ca])
        precondition(openTAKChain == [leafData, caData])
        let numberedChain = try chain(["signedCert": leaf, "ca0": ca, "ca1": otherCA])
        precondition(numberedChain == [leafData, caData, otherCAData])
        let orderedChain = try chain(["signedCert": leaf, "ca10": otherCA, "ca2": ca, "ca": otherCA])
        precondition(orderedChain == [leafData, otherCAData, caData, otherCAData])
        let leafOnlyChain = try chain(["signedCert": leaf])
        precondition(leafOnlyChain == [leafData])
        do {
            _ = try chain(["signedCert": leaf, "ca": "invalid certificate"])
            fatalError("Malformed OpenTAKServer CA accepted")
        } catch {}
        do {
            _ = try EnrollmentClient.signingChain(from: Data(#"{"signedCert":"invalid","ca":42}"#.utf8))
            fatalError("Non-string enrollment CA accepted")
        } catch {}
    }

    static func checkServerTrust(in directory: URL, client: SecCertificate) throws {
        let extensions = """
        basicConstraints=critical,CA:FALSE
        keyUsage=critical,digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        subjectAltName=DNS:fixture.example,DNS:takserver2,DNS:fixture.example,DNS:*.example.net,IP:127.0.0.1
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
        let names = try CertificateStore.dnsSubjectAlternativeNames(server)
        precondition(names == ["fixture.example", "takserver2"])
        let noSAN = try CertificateStore.dnsSubjectAlternativeNames(ca)
        precondition(noSAN.isEmpty)
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
        try evaluate(host: "takserver2", chain: [client, ca])
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
        func inspect(expired: Bool = false, explicitCA: Data? = caData) throws -> [String] {
            var trust: SecTrust?
            let status = SecTrustCreateWithCertificates([server, ca] as CFArray,
                                                       SecPolicyCreateSSL(true, nil), &trust)
            guard status == errSecSuccess, let trust else { fatalError("Fixture trust failed") }
            SecTrustSetNetworkFetchAllowed(trust, false)
            SecTrustSetVerifyDate(trust, (expired ? Date().addingTimeInterval(3 * 86_400) : Date()) as CFDate)
            return try CertificateStore.inspectServerTrust(trust, certificates: [client], trustedCA: explicitCA)
        }
        let inspected = try inspect()
        precondition(inspected == names)
        do {
            _ = try inspect(expired: true)
            fatalError("Inspection accepted expired certificate")
        } catch {}
        do {
            _ = try inspect(explicitCA: nil)
            fatalError("Inspection accepted untrusted private CA")
        } catch {}
        do {
            _ = try inspect(explicitCA: SecCertificateCopyData(otherCA) as Data)
            fatalError("Inspection bypassed explicit CA")
        } catch {}
    }

    @MainActor
    static func checkCertificateInspection(in directory: URL) async throws {
        try openssl(["pkcs12", "-export", "-inkey", "server.key", "-in", "server.pem", "-certfile", "ca.pem",
                     "-out", "server.p12", "-passout", "pass:fixture-only"], in: directory)
        let stored = try CertificateStore.importP12(Data(contentsOf: directory.appendingPathComponent("server.p12")),
                                                    password: "fixture-only")
        let identity = try CertificateStore.resolve(stored)
        let fixture = try InspectionTLSFixture(identity: identity)
        defer { fixture.stop() }
        let port = try await fixture.start()
        let ca = try CertificateStore.decodeCertificate(String(contentsOf: directory.appendingPathComponent("ca.pem"),
                                                                encoding: .utf8))
        let inspector = ServerCertificateInspection()
        let names = try await inspector.inspect(host: "127.0.0.1", port: port,
                                                                    certificates: [], trustedCA: ca)
        precondition(names == ["fixture.example", "takserver2"])
        let repeated = try await inspector.inspect(host: "127.0.0.1", port: port, certificates: [], trustedCA: ca)
        precondition(repeated == names)
        let privateNames = try await inspector.inspect(host: "127.0.0.1", port: port,
                                                       certificates: [], trustedCA: ca, automatic: true)
        precondition(privateNames == names)
        do {
            _ = try await inspector.inspect(host: "127.0.0.1", port: port,
                                             certificates: [], trustedCA: nil, automatic: true)
            fatalError("Automatic inspection accepted a server without a stored CA")
        } catch {}
        do {
            _ = try await ServerCertificateInspection().inspect(host: "127.0.0.1", port: port,
                                                                 certificates: [], trustedCA: nil)
            fatalError("Live inspection accepted an untrusted CA")
        } catch {}
        let cancelled = Task {
            try await inspector.inspect(host: "127.0.0.1", port: port,
                                                             certificates: [], trustedCA: ca)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            fatalError("Cancelled inspection succeeded")
        } catch is CancellationError {}
        do {
            _ = try await inspector.inspect(host: "127.0.0.1", port: 0, certificates: [], trustedCA: ca)
            fatalError("Inspection accepted invalid port")
        } catch CompanionFailure.message {}
        precondition(fixture.completedHandshakes == 0)
        print("PASS: live TLS inspection returns exact SANs without completing a handshake; untrusted CA and cancellation rejected")

        try Data("""
        basicConstraints=critical,CA:FALSE
        keyUsage=critical,digitalSignature,keyEncipherment
        extendedKeyUsage=serverAuth
        subjectAltName=DNS:takserver2
        """.utf8).write(to: directory.appendingPathComponent("automatic.ext"))
        try openssl(["x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key",
                     "-CAcreateserial", "-out", "automatic.pem", "-days", "1", "-extfile", "automatic.ext"], in: directory)
        try openssl(["pkcs12", "-export", "-inkey", "server.key", "-in", "automatic.pem", "-certfile", "ca.pem",
                     "-out", "automatic.p12", "-passout", "pass:fixture-only"], in: directory)
        let automaticStored = try CertificateStore.importP12(
            Data(contentsOf: directory.appendingPathComponent("automatic.p12")), password: "fixture-only")
        let automaticIdentity = try CertificateStore.resolve(automaticStored)
        let automaticFixture = try InspectionTLSFixture(identity: automaticIdentity)
        defer { automaticFixture.stop() }
        let automaticPort = try await automaticFixture.start()
        let connection = TAKServerConnection()
        defer { connection.disconnect() }
        var recoveredName: String?
        var recoveryError: Error?
        var recoveryTask: Task<Void, Never>?
        defer { recoveryTask?.cancel() }
        connection.onHostnameMismatch = {
            recoveryTask = Task {
                do {
                    let discovered = try await ServerCertificateInspection().inspect(host: "127.0.0.1",
                        port: automaticPort, certificates: [], trustedCA: ca, automatic: true)
                    let name = try CertificateStore.automaticTLSName(discovered)
                    recoveredName = name
                    try connection.connect(endpoint: CompanionEndpoint(host: "127.0.0.1",
                        streamPort: automaticPort, enrollmentPort: 8446),
                        identity: automaticIdentity, trustedCA: ca, streamTLSName: name)
                } catch { recoveryError = error }
            }
        }
        try connection.connect(endpoint: CompanionEndpoint(host: "127.0.0.1", streamPort: automaticPort,
                                                            enrollmentPort: 8446),
                               identity: automaticIdentity, trustedCA: ca)
        for _ in 0..<100 {
            if connection.ready || recoveryError != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let recoveryError { throw recoveryError }
        precondition(connection.ready && recoveredName == "takserver2")
        print("PASS: hostname mismatch triggers private-CA SAN discovery and reconnects with takserver2")
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

    @MainActor
    private final class InspectionTLSFixture {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "WearTAK.InspectionFixture")
        private var connections: [NWConnection] = []
        private(set) var completedHandshakes = 0

        init(identity: ClientIdentity) throws {
            let tls = NWProtocolTLS.Options()
            guard let local = sec_identity_create_with_certificates(identity.identity, identity.certificates as CFArray) else {
                throw CompanionFailure.message("Fixture server identity failed.")
            }
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, local)
            listener = try NWListener(using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()), on: .any)
        }

        func start() async throws -> Int {
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self else { connection.cancel(); return }
                    self.connections.append(connection)
                    connection.stateUpdateHandler = { [weak self] state in
                        if case .ready = state {
                            Task { @MainActor in self?.completedHandshakes += 1 }
                        }
                    }
                    connection.start(queue: self.queue)
                }
            }
            return try await withCheckedThrowingContinuation { continuation in
                listener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.listener.stateUpdateHandler = nil
                            guard let port = self.listener.port else {
                                continuation.resume(throwing: CompanionFailure.message("Fixture listener has no port."))
                                return
                            }
                            continuation.resume(returning: Int(port.rawValue))
                        case .failed(let error):
                            self.listener.stateUpdateHandler = nil
                            continuation.resume(throwing: error)
                        default: break
                        }
                    }
                }
                listener.start(queue: queue)
            }
        }

        func stop() {
            listener.cancel()
            for connection in connections { connection.cancel() }
        }
    }
}