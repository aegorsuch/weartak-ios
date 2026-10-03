import Foundation
import Security

@main
struct CompanionSecurityChecks {
    static func main() throws {
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
        print("PASS: PKCS#10 CSR signature, subject encoding, key match, expiry and .p12 identity/password checks")
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