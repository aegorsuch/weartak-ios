import Foundation
#if canImport(OSLog)
import OSLog
#endif

nonisolated enum DiagnosticEvent: String, Codable, CaseIterable {
    case enabled, launched, foreground, background, lowPower, normalPower, thermalElevated, thermalNormal
    case batteryLow, batteryNormal
    case reportingStarted, reportingStopped, reportSent, reportFailed, locationAccepted, locationRejected
    case sensorStarted, sensorStopped, sensorSample, sensorUnavailable
    case connectivityChanged, syncUpdated, mapUpdated, operationFailed
}

nonisolated struct DiagnosticEntry: Codable, Equatable {
    let time: Date
    let event: DiagnosticEvent
}

nonisolated final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()
    static let enabledKey = "WearTAK.diagnostics.enabled"
    static let maximumEntries = 256
    static let maximumBytes = 48_000
    static let minimumEventInterval: TimeInterval = 30
    static let requestKey = "WearTAK.diagnostics.request"
    private let lock = NSLock()
    private let defaults: UserDefaults
    private let directory: URL?
    private var entries: [DiagnosticEntry]?
    private var failed = false
    private var retryAfter: Date?

    private struct Archive: Codable {
        let version: Int
        let entries: [DiagnosticEntry]
    }

    enum Failure: LocalizedError {
        case storage, invalidArchive
        var errorDescription: String? {
            switch self {
            case .storage: return "Diagnostics storage is unavailable. Check available storage and try again."
            case .invalidArchive: return "The diagnostics file could not be read safely."
            }
        }
    }

    init(defaults: UserDefaults = .standard, directory: URL? = nil) {
        self.defaults = defaults
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("WearTAKDiagnostics", isDirectory: true)
    }

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return defaults.bool(forKey: Self.enabledKey)
    }

    var hasStorageFailure: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    func setEnabled(_ enabled: Bool, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        if enabled {
            do {
                try load()
                append(.enabled, at: now)
                try persist()
            } catch {
                failed = true
                entries = nil
                throw Failure.storage
            }
        }
        defaults.set(enabled, forKey: Self.enabledKey)
        failed = false
        retryAfter = nil
    }

    func record(_ event: DiagnosticEvent, at now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard defaults.bool(forKey: Self.enabledKey) else { return }
        guard retryAfter.map({ now >= $0 }) ?? true else { return }
        do {
            try load()
            if let previous = entries?.last(where: { $0.event == event }),
               now.timeIntervalSince(previous.time) < Self.minimumEventInterval { return }
            append(event, at: now)
            try persist()
            failed = false
            retryAfter = nil
        } catch {
            failed = true
            entries = nil
            retryAfter = now.addingTimeInterval(Self.minimumEventInterval)
            #if canImport(OSLog)
            Logger(subsystem: "com.aegorsuch.weartak", category: "Diagnostics")
                .error("Opt-in diagnostics could not be persisted.")
            #endif
        }
    }

    func export() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { throw Failure.storage }
        try load()
        return try encoded()
    }

    static func validatedExport(_ data: Data) throws -> Data {
        guard data.count <= maximumBytes else { throw Failure.invalidArchive }
        let archive: Archive
        do { archive = try JSONDecoder().decode(Archive.self, from: data) }
        catch { throw Failure.invalidArchive }
        guard archive.version == 1, archive.entries.count <= maximumEntries,
              archive.entries.allSatisfy({ $0.time.timeIntervalSince1970.isFinite }) else {
            throw Failure.invalidArchive
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(archive)
    }

    static func exportFile(_ data: Data, watch: Bool) throws -> URL {
        let safe = try validatedExport(data)
        let name = watch ? "WearTAK-Watch-Diagnostics.json" : "WearTAK-Phone-Diagnostics.json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try safe.write(to: url, options: .atomic)
        return url
    }

    private func append(_ event: DiagnosticEvent, at time: Date) {
        entries = Array(((entries ?? []) + [DiagnosticEntry(time: time, event: event)]).suffix(Self.maximumEntries))
    }

    private func load() throws {
        guard entries == nil else { return }
        guard let directory else { throw Failure.storage }
        let url = directory.appendingPathComponent("events.json")
        guard FileManager.default.fileExists(atPath: url.path) else { entries = []; return }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Self.maximumBytes + 1
        guard size <= Self.maximumBytes else { throw Failure.invalidArchive }
        let data = try Self.validatedExport(Data(contentsOf: url))
        entries = try JSONDecoder().decode(Archive.self, from: data).entries
    }

    private func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(Archive(version: 1, entries: entries ?? []))
        guard data.count <= Self.maximumBytes else { throw Failure.storage }
        return data
    }

    private func persist() throws {
        guard var directory else { throw Failure.storage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try encoded().write(to: directory.appendingPathComponent("events.json"), options: .atomic)
    }
}

nonisolated enum DeveloperPreference: String, Identifiable, CaseIterable {
    case betaFeatures = "Beta Features"
    case collectWatch = "Collect Watch Diagnostics"
    case developerMode = "Developer mode"
    case diagnostics = "Diagnostics"
    case exportDiagnostics = "Export Diagnostics"
    case viewDiagnostics = "View Diagnostics"

    var id: String { rawValue }
    static func sorted(_ items: [Self], title: (Self) -> String) -> [Self] {
        items.sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
    }
}
