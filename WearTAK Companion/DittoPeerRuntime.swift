import DittoSwift
import Foundation
import OSLog

@MainActor
final class DittoPeerRuntime {
    private static let enabledKey = "WearTAK.companion.dittoEnabled"
    private static let sourceKey = "WearTAK.companion.dittoIdentitySource"
    private let defaults: UserDefaults
    private let pdlStore: SecurePDLStore
    private let communityPDL: String?
    private let logger = Logger(subsystem: "com.aegorsuch.weartak", category: "Ditto")
    private var configuration = DittoBridgeConfiguration(enabled: false, source: .community)
    private var foreground = true
    private var instance: Ditto?
    private var subscriptions: [DittoSyncSubscription] = []
    private var observers: [DittoStoreObserver] = []
    private var ingress = DittoIngress()
    private var chatEvictionInFlight = false
    var ownUID: (() -> String?)?
    var onEvent: ((String) -> Void)?
    private var generation = 0
    private var operation: Task<Void, Never>?
    private var configurationError: String?
    private(set) var status = DittoBridgeStatus(enabled: false, source: .community, state: .off,
        detail: "Ditto sync is off.")
    var onStatusChange: ((DittoBridgeStatus) -> Void)?

    init(defaults: UserDefaults, communityPDL: String?, pdlStore: SecurePDLStore) {
        self.defaults = defaults
        self.communityPDL = communityPDL?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pdlStore = pdlStore
        Ditto.shouldWaitForCleanupOnClose = true
    }

    func restore(isForeground: Bool) async -> DittoBridgeStatus {
        foreground = isForeground
        let source = DittoIdentitySource(rawValue: defaults.string(forKey: Self.sourceKey) ?? "") ?? .community
        let customPDL: String?
        do {
            customPDL = source == .custom ? try pdlStore.read() : nil
        } catch {
            configurationError = error.localizedDescription
            updateStatus(DittoBridgeStatus(enabled: defaults.bool(forKey: Self.enabledKey), source: source,
                state: .failed, detail: error.localizedDescription))
            return status
        }
        configuration = DittoBridgeConfiguration(enabled: defaults.bool(forKey: Self.enabledKey),
            source: source, customPDL: customPDL)
        if source == .custom, configuration.enabled, configuration.customPDL == nil {
            updateStatus(DittoBridgeStatus(enabled: true, source: source, state: .failed,
                detail: "Custom PDL is missing from the iPhone Keychain. Send it again from the watch."))
            return status
        }
        configurationError = nil
        await reconcile()
        return status
    }

    func apply(_ newConfiguration: DittoBridgeConfiguration) async -> DittoBridgeStatus {
        guard newConfiguration.isValid else {
            updateStatus(DittoBridgeStatus(enabled: newConfiguration.enabled, source: newConfiguration.source,
                state: .failed, detail: "The Ditto configuration is incomplete or too large."))
            return status
        }

        configuration = newConfiguration
        defaults.set(newConfiguration.enabled, forKey: Self.enabledKey)
        defaults.set(newConfiguration.source.rawValue, forKey: Self.sourceKey)
        configurationError = nil
        do {
            if newConfiguration.source == .custom, let pdl = newConfiguration.customPDL {
                _ = try DittoPDLParser.parse(pdl)
                try pdlStore.write(pdl)
            } else if newConfiguration.source == .custom {
                // The watch cleared its custom PDL; never fall back to the stale iPhone copy on restart.
                try pdlStore.delete()
            }
        } catch {
            logger.error("Ditto identity validation failed: \(error.localizedDescription, privacy: .public)")
            configurationError = error.localizedDescription
            await reconcile()
            return status
        }

        await reconcile()
        return status
    }

    func setForeground(_ isForeground: Bool) async -> DittoBridgeStatus {
        foreground = isForeground
        await reconcile()
        return status
    }

    private func reconcile() async {
        generation += 1
        let requestedGeneration = generation
        let previous = operation
        let next = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.generation == requestedGeneration else { return }
            await self.performReconcile(generation: requestedGeneration)
        }
        operation = next
        await next.value
    }

    private func performReconcile(generation requestedGeneration: Int) async {
        releaseCurrentInstance()
        guard generation == requestedGeneration else { return }

        guard configuration.enabled else {
            updateStatus(DittoBridgeStatus(enabled: false, source: configuration.source, state: .off,
                detail: "Ditto sync is off."))
            return
        }
        if let configurationError {
            updateStatus(DittoBridgeStatus(enabled: true, source: configuration.source, state: .failed,
                detail: String(configurationError.prefix(400))))
            return
        }
        guard foreground else {
            updateStatus(DittoBridgeStatus(enabled: true, source: configuration.source, state: .paused,
                detail: "Paused while WearTAK Companion is in the background; iOS does not allow continuous background sync."))
            return
        }

        updateStatus(DittoBridgeStatus(enabled: true, source: configuration.source, state: .starting,
            detail: "Starting Ditto peer-to-peer sync on iPhone."))
        do {
            let pdlText: String
            if configuration.source == .community {
                guard let communityPDL, !communityPDL.isEmpty else { throw DittoPDLError.missing }
                pdlText = communityPDL
            } else if let customPDL = configuration.customPDL, !customPDL.isEmpty {
                pdlText = customPDL
            } else {
                throw DittoPDLError.missing
            }
            let pdl = try DittoPDLParser.parse(pdlText)
            guard generation == requestedGeneration else { return }
            let config = DittoConfig(databaseID: pdl.appID,
                connect: .smallPeersOnly(privateKey: pdl.sharedKey))
            let opened = try await Ditto.open(config: config)
            guard generation == requestedGeneration else { return }
            try opened.setOfflineOnlyLicenseToken(pdl.licenseToken)
            instance = opened
            for collection in DittoCoTDocument.collections {
                subscriptions.append(try opened.sync.registerSubscription(query: "SELECT * FROM \(collection)"))
                let observer = try opened.store.registerObserver(query: "SELECT * FROM \(collection)") { [weak self] result in
                    // Materialize within the SDK callback; never retain SDK result items across an actor hop.
                    let items = result.items
                    guard items.count <= 4_096 else {
                        Task { @MainActor [weak self] in self?.logger.error("Ditto snapshot rejected: more than4096 documents") }
                        return
                    }
                    var documents: [[String: Any]] = []
                    var bytes = 0
                    for item in items {
                        let value = item.value
                        item.dematerialize()
                        bytes += (value["r"] as? String)?.utf8.count ?? 0
                        guard bytes <= 4_194_304 else {
                            Task { @MainActor [weak self] in self?.logger.error("Ditto snapshot rejected: detail byte budget exceeded") }
                            return
                        }
                        documents.append(value)
                    }
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == requestedGeneration else { return }
                        self.receive(documents, collection: collection)
                    }
                }
                observers.append(observer)
            }
            try opened.sync.start()
            guard generation == requestedGeneration else {
                opened.sync.stop()
                releaseCurrentInstance()
                return
            }
            updateStatus(DittoBridgeStatus(enabled: true, source: configuration.source, state: .syncing,
                detail: "Sync enabled on iPhone while Companion is open. Peer discovery may take time."))
        } catch {
            releaseCurrentInstance()
            logger.error("Ditto startup failed: \(error.localizedDescription, privacy: .public)")
            updateStatus(DittoBridgeStatus(enabled: true, source: configuration.source, state: .failed,
                detail: String(error.localizedDescription.prefix(400))))
        }
    }

    private func receive(_ documents: [[String: Any]], collection: String) {
        guard let instance, foreground, configuration.enabled, let uid = ownUID?() else { return }
        for raw in documents {
            if raw["_r"] as? Bool == true || raw["visible"] as? Bool == false || raw["f"] as? Bool == false { continue }
            do {
                let doc = try DittoCoTDocument.decode(raw, collection: collection)
                if collection == "chat" {
                    if doc.stale <= Date() { evictExpiredChat(); continue }
                    guard let chat = TAKChatMessage.parse(doc.xml, ownUID: uid),
                          chat.senderUID != uid, doc.author == chat.senderUID else { continue }
                }
                guard ingress.accept(doc, ownUID: uid, localPeer: instance.presence.graph.localPeer.peerKey) else { continue }
                onEvent?(doc.xml)
            } catch {
                logger.error("Rejected Ditto \(collection, privacy: .public) document: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func evictExpiredChat() {
        guard !chatEvictionInFlight, let instance else { return }
        chatEvictionInFlight = true
        Task {
            defer { chatEvictionInFlight = false }
            do {
                try await instance.store.execute(query: "EVICT FROM chat WHERE o <= :now",
                    arguments: ["now": (Date().timeIntervalSince1970 * 1_000).rounded()])
            } catch { logger.error("Ditto expired chat eviction failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func publishEvent(_ xml: String, uid: String, callsign: String) async -> Bool {
        guard let instance, instance.sync.isActive else { return false }
        do {
            let (collection, doc) = try DittoCoTDocument.make(xml: xml,
                peer: instance.presence.graph.localPeer.peerKey, author: uid, callsign: callsign)
            guard collection != "track" else { throw DittoCoTDocument.Failure.invalid }
            try await instance.store.execute(query: "INSERT INTO \(collection) DOCUMENTS (:doc) ON ID CONFLICT DO UPDATE",
                                             arguments: ["doc": doc])
            return true
        } catch {
            logger.error("Ditto publication failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Upserts the watch's PLI into `track` in WearTAK-Tracker's document format. Returns false when sync is not running.
    @discardableResult
    func publishTrack(pliXML xml: String) async -> Bool {
        guard let instance, instance.sync.isActive else { return false }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        guard let document = DittoTrackDocument.make(fromPLI: xml,
                peerKey: instance.presence.graph.localPeer.peerKey, appVersion: version) else {
            logger.error("Ditto track update skipped: PLI is not a valid self-position event")
            return false
        }
        do {
            try await instance.store.execute(query: DittoTrackDocument.upsertQuery, arguments: ["doc": document])
            return true
        } catch {
            logger.error("Ditto track update failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func releaseCurrentInstance() {
        if let instance, instance.sync.isActive { instance.sync.stop() }
        observers.forEach { $0.cancel() }
        observers.removeAll()
        subscriptions.forEach { $0.cancel() }
        subscriptions.removeAll()
        ingress = DittoIngress()
        instance = nil
    }

    private func updateStatus(_ value: DittoBridgeStatus) {
        status = value
        onStatusChange?(value)
    }
}
