import Foundation
import Network
import Security

@MainActor
final class TAKServerConnection {
    private let queue = DispatchQueue(label: "WearTAK.Companion.TLS")
    private var connection: NWConnection?
    private var framer = CoTStreamFramer()
    private var timeoutTask: Task<Void, Never>?
    private(set) var ready = false
    var onState: ((Bool, String) -> Void)?
    var onCoT: ((String) -> Void)?

    func connect(endpoint: CompanionEndpoint, identity: ClientIdentity, trustedCA: Data?) throws {
        disconnect()
        let tls = NWProtocolTLS.Options()
        guard let localIdentity = sec_identity_create_with_certificates(identity.identity, identity.certificates as CFArray) else {
            throw CompanionFailure.message("Unable to configure TLS client identity.")
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, localIdentity)
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, endpoint.host)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let anchors: [SecCertificate]
        if let trustedCA, let ca = SecCertificateCreateWithData(nil, trustedCA as CFData) { anchors = [ca] }
        else { anchors = Array(identity.certificates.dropFirst()) }
        let host = endpoint.host
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, securityTrust, complete in
            let trust = sec_trust_copy_ref(securityTrust).takeRetainedValue()
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
            if !anchors.isEmpty {
                SecTrustSetAnchorCertificates(trust, anchors as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
            }
            var error: CFError?
            complete(SecTrustEvaluateWithError(trust, &error))
        }, queue)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        guard let port = NWEndpoint.Port(rawValue: UInt16(endpoint.streamPort)) else {
            throw CompanionFailure.message("Invalid TLS port.")
        }
        let socket = NWConnection(host: .init(endpoint.host), port: port, using: parameters)
        connection = socket
        framer = CoTStreamFramer()
        onState?(false, "Connecting")
        socket.stateUpdateHandler = { [weak self, weak socket] state in
            Task { @MainActor in
                guard let self, let socket, self.connection === socket else { return }
                switch state {
                case .ready:
                    self.timeoutTask?.cancel()
                    self.ready = true
                    self.onState?(true, "Connected")
                    self.receive(socket)
                case .waiting(let error), .failed(let error):
                    self.fail(socket, message: error.localizedDescription)
                case .cancelled:
                    self.ready = false
                default: break
                }
            }
        }
        socket.start(queue: queue)
        timeoutTask = Task { [weak self, weak socket] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, let socket, self.connection === socket, !self.ready else { return }
            self.fail(socket, message: "Connection timed out. Check the server, port, and certificate.")
        }
    }

    func disconnect() {
        timeoutTask?.cancel()
        timeoutTask = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        ready = false
    }

    func send(_ xml: String) async throws {
        let data = Data(xml.utf8)
        guard CoTStreamFramer.isEvent(data), ready, let socket = connection else {
            throw CompanionFailure.message("TAK server is not connected.")
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                socket.send(content: data, completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                })
            }
        } catch {
            fail(socket, message: "Server write failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func receive(_ socket: NWConnection) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak socket] data, _, complete, error in
            Task { @MainActor in
                guard let self, let socket, self.connection === socket else { return }
                do {
                    if let data {
                        for event in try self.framer.append(data) {
                            self.onCoT?(String(decoding: event, as: UTF8.self))
                        }
                    }
                } catch {
                    self.fail(socket, message: "Invalid or oversized CoT stream.")
                    return
                }
                if let error { self.fail(socket, message: error.localizedDescription) }
                else if complete { self.fail(socket, message: "Server closed the connection.") }
                else { self.receive(socket) }
            }
        }
    }

    private func fail(_ socket: NWConnection, message: String) {
        guard connection === socket else { return }
        disconnect()
        onState?(false, message)
    }
}