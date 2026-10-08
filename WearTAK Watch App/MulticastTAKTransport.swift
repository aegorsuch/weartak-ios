import Combine
import Foundation
import Network
import OSLog

@MainActor
protocol CoTOutput {
    var isReady: Bool { get }
    func send(_ xml: String) async throws
}
@MainActor
final class MulticastTAKTransport: ObservableObject, CoTOutput {
    @Published private(set) var status = "Disabled"
    @Published private(set) var isReady = false
    @Published private(set) var sentDatagrams = 0
    @Published private(set) var receivedDatagrams = 0
    @Published private(set) var lastSentAt: Date?
    @Published private(set) var lastSendError: String?
    @Published private(set) var rejectedDatagrams = 0
    @Published private(set) var lastReceiveError: String?
    var onStateChange: (() -> Void)?
    var onEntity: ((EntityRelayPayload) -> Void)?
    var onChat: ((TAKChatMessage) -> Void)?

    private let settings: AppSettings
    private let queue = DispatchQueue(label: "WearTAK.multicast")
    private var groups: [TAKMulticastEndpoint: NWConnectionGroup] = [:]
    private var readyEndpoints: Set<TAKMulticastEndpoint> = []
    private let logger = Logger(subsystem: "com.aegorsuch.weartak", category: "Multicast")
    private var subscription: AnyCancellable?
    private var retryTask: Task<Void, Never>?
    private var isAppActive = false
    private var generation = 0

    init(settings: AppSettings) {
        self.settings = settings
        subscription = Publishers.CombineLatest4(
            settings.$multicastEnabled, settings.$multicastAddress,
            settings.$multicastPort, settings.$multicastOutputProtocol
        )
        .dropFirst()
        .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
        .sink { [weak self] _ in self?.configure() }
    }

    func setAppActive(_ active: Bool) {
        isAppActive = active
        configure()
    }

    private func stop() {
        generation += 1
        retryTask?.cancel()
        for group in groups.values { group.cancel() }
        groups = [:]
        readyEndpoints = []
        isReady = false
        onStateChange?()
    }

    private func configure() {
        stop()
        guard settings.multicastEnabled else {
            status = "Disabled"
            return
        }
        guard isAppActive else {
            status = "App inactive"
            return
        }
        guard AppSettings.isMulticastAddress(settings.multicastAddress),
            (1...65535).contains(settings.multicastPort)
        else {
            status = "Invalid address or port"
            return
        }
        do {
            for destination in TAKMulticast.receiveEndpoints(
                address: settings.multicastAddress, port: settings.multicastPort)
            {
                guard let port = NWEndpoint.Port(rawValue: UInt16(destination.port)) else {
                    throw MulticastError.invalidPort
                }
                let endpoint = NWEndpoint.hostPort(host: .init(destination.address), port: port)
                let descriptor = try NWMulticastGroup(for: [endpoint])
                let parameters = NWParameters.udp
                parameters.allowLocalEndpointReuse = true
                parameters.requiredInterfaceType = .wifi
                let connection = NWConnectionGroup(with: descriptor, using: parameters)
                let currentGeneration = generation
                groups[destination] = connection
                status = "Connecting"
                connection.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == currentGeneration else { return }
                        switch state {
                        case .ready:
                            self.readyEndpoints.insert(destination)
                        case .waiting(let error):
                            self.readyEndpoints.remove(destination)
                            self.status =
                                "Waiting: \(destination.address):\(destination.port): \(error.localizedDescription)"
                            self.logger.notice("Multicast waiting: \(self.status, privacy: .public)")
                        case .failed(let error):
                            self.readyEndpoints.remove(destination)
                            self.status =
                                "Failed: \(destination.address):\(destination.port): \(error.localizedDescription)"
                            self.logger.notice("Multicast failed: \(self.status, privacy: .public)")
                            self.retryTask?.cancel()
                            self.retryTask = Task { [weak self] in
                                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                                self?.configure()
                            }
                        case .cancelled:
                            self.readyEndpoints.remove(destination)
                        case .setup:
                            break
                        @unknown default:
                            break
                        }
                        self.isReady = self.readyEndpoints.contains(
                            TAKMulticastEndpoint(
                                address: self.settings.multicastAddress, port: self.settings.multicastPort))
                        if self.readyEndpoints.count == self.groups.count { self.status = "Ready" }
                        self.onStateChange?()
                    }
                }
                connection.setReceiveHandler(maximumMessageSize: 65_507, rejectOversizedMessages: true) {
                    [weak self] _, data, complete in
                    guard complete, let data else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == currentGeneration, self.isAppActive,
                            self.settings.multicastEnabled
                        else { return }
                        self.receivedDatagrams += 1
                        self.logger.debug(
                            "Multicast ingress \(destination.address, privacy: .public):\(destination.port) \(data.count) bytes"
                        )
                        let xml: String
                        do {
                            guard let decoded = try TAKDatagramDecoder.decode(data) else {
                                self.logger.debug("Control-only TAK datagram")
                                return
                            }
                            xml = decoded
                            self.lastReceiveError = nil
                        } catch {
                            self.rejectedDatagrams += 1
                            self.lastReceiveError = error.localizedDescription
                            self.logger.notice(
                                "Multicast datagram rejected: \(error.localizedDescription, privacy: .public)")
                            return
                        }
                        if let chat = TAKChatMessage.parse(xml, ownUID: SitxClient.deviceID()) {
                            self.onChat?(chat)
                            return
                        }
                        for entity in SitxCoT.parse(Data(xml.utf8), excluding: SitxClient.deviceID()) {
                            self.onEntity?(entity)
                        }
                    }
                }
                connection.start(queue: queue)
            }
        } catch {
            stop()
            status = "Failed: \(error.localizedDescription)"
        }
    }

    func send(_ xml: String) async throws {
        let (prepared, destination) = TAKMulticast.outbound(
            xml, address: settings.multicastAddress, port: settings.multicastPort)
        guard settings.multicastEnabled, isAppActive, readyEndpoints.contains(destination),
            let group = groups[destination]
        else {
            throw TAKTransportError.notConfigured
        }
        let data = Data(prepared.utf8)
        guard data.count <= 65_507 else { throw MulticastError.datagramTooLarge }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                group.send(content: data) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            sentDatagrams += 1
            lastSentAt = Date()
            lastSendError = nil
        } catch {
            lastSendError = error.localizedDescription
            throw error
        }
    }
}
private enum MulticastError: Error {
    case datagramTooLarge
    case invalidPort
}
