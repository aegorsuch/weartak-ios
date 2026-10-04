import Combine
import Foundation
import Network

@MainActor
protocol CoTOutput {
    var isReady: Bool { get }
    func send(_ xml: String) async throws
}

@MainActor
final class MulticastTAKTransport: ObservableObject, CoTOutput {
    @Published private(set) var status = "Disabled"
    @Published private(set) var isReady = false
    var onStateChange: (() -> Void)?
    var onEntity: ((EntityRelayPayload) -> Void)?
    var onChat: ((TAKChatMessage) -> Void)?

    private let settings: AppSettings
    private let queue = DispatchQueue(label: "WearTAK.multicast")
    private var group: NWConnectionGroup?
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
        group?.cancel()
        group = nil
        isReady = false
        onStateChange?()
    }

    private func configure() {
        stop()
        guard settings.multicastEnabled else { status = "Disabled"; return }
        guard isAppActive else { status = "App inactive"; return }
        guard AppSettings.isMulticastAddress(settings.multicastAddress),
              let port = NWEndpoint.Port(rawValue: UInt16(exactly: settings.multicastPort) ?? 0),
              port.rawValue != 0 else { status = "Invalid address or port"; return }
        do {
            let endpoint = NWEndpoint.hostPort(host: .init(settings.multicastAddress), port: port)
            let descriptor = try NWMulticastGroup(for: [endpoint])
            let parameters = NWParameters.udp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredInterfaceType = .wifi
            let connection = NWConnectionGroup(with: descriptor, using: parameters)
            let currentGeneration = generation
            group = connection
            status = "Connecting"
            connection.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == currentGeneration else { return }
                    switch state {
                    case .ready:
                        self.isReady = true
                        self.status = "Ready"
                    case .waiting(let error):
                        self.isReady = false
                        self.status = "Waiting: \(error.localizedDescription)"
                    case .failed(let error):
                        self.isReady = false
                        self.status = "Failed: \(error.localizedDescription)"
                        self.retryTask = Task { [weak self] in
                            do { try await Task.sleep(for: .seconds(10)) } catch { return }
                            self?.configure()
                        }
                    case .cancelled:
                        self.isReady = false
                    case .setup:
                        break
                    @unknown default:
                        break
                    }
                    self.onStateChange?()
                }
            }
            connection.setReceiveHandler(maximumMessageSize: 65_507, rejectOversizedMessages: true) { [weak self] _, data, complete in
                guard complete, let data else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == currentGeneration, self.isAppActive,
                          self.settings.multicastEnabled else { return }
                    if let chat = TAKChatMessage.parse(String(decoding: data, as: UTF8.self), ownUID: SitxClient.deviceID()) {
                        self.onChat?(chat)
                        return
                    }
                    for entity in SitxCoT.parse(data, excluding: SitxClient.deviceID()) {
                        self.onEntity?(entity)
                    }
                }
            }
            connection.start(queue: queue)
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }

    func send(_ xml: String) async throws {
        guard settings.multicastEnabled, isAppActive, isReady, let group else {
            throw TAKTransportError.notConfigured
        }
        let data = Data(xml.utf8)
        guard data.count <= 65_507 else { throw MulticastError.datagramTooLarge }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            group.send(content: data) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

private enum MulticastError: Error {
    case datagramTooLarge
}