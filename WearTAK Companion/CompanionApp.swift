import os
import SwiftUI
import UniformTypeIdentifiers

@main
struct WearTAKCompanionApp: App {
    var body: some Scene {
        WindowGroup { CompanionSetupView() }
    }
}

struct CompanionSetupView: View {
    @StateObject private var bridge: PhoneBridgeModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var editor: ServerEditorRoute?
    @State private var serverToRemove: CompanionServer?
    @State private var confirmRemove = false
    @State private var errorText: String?
    @State private var showDeveloperModeEnabled = false

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--preview-servers") {
            let defaults = UserDefaults(suiteName: "WearTAK.Companion.Preview")!
            let samples = [
                CompanionServer(endpoint: CompanionEndpoint(host: "192.0.2.1", streamPort: 8089, enrollmentPort: 8446)),
                CompanionServer(endpoint: CompanionEndpoint(host: "192.0.2.2", streamPort: 8089, enrollmentPort: 8446))
            ]
            defaults.set(try? JSONEncoder().encode(samples), forKey: "WearTAK.companion.servers")
            _bridge = StateObject(wrappedValue: PhoneBridgeModel(defaults: defaults))
            return
        }
        #endif
        _bridge = StateObject(wrappedValue: PhoneBridgeModel())
    }

    var body: some View {
        NavigationStack {
            List {
                TLSApprovalSection(bridge: bridge)
                Section {
                    LabeledContent(
                        String(localized: "Reporting status", table: "PhoneLocationReporting"),
                        value: bridge.phoneReporting.state
                    )
                    DisclosureGroup(String(localized: "Details", table: "PhoneLocationReporting")) {
                        LabeledContent(
                            String(localized: "Location permission", table: "PhoneLocationReporting"),
                            value: bridge.phoneReporting.permission
                        )
                        LabeledContent(
                            String(localized: "Last position sent", table: "PhoneLocationReporting"),
                            value: bridge.phoneReporting.lastReportAt?.formatted(date: .abbreviated, time: .shortened)
                                ?? String(localized: "No positions sent yet", table: "PhoneLocationReporting")
                        )
                        if let detail = bridge.phoneReporting.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("Companion uses this iPhone's GPS to send your paired watch's position to configured TAK servers while this phone is locked. Reporting starts automatically when a paired watch selects Companion as its relay and an enabled server with a client certificate is available. Background reporting requires Location Services, Precise Location, and Always permission; While Using access supports reporting only while Companion is open.", tableName: "PhoneLocationReporting")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "Open Location Settings", table: "PhoneLocationReporting")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                } header: {
                    Text("Background location reporting", tableName: "PhoneLocationReporting")
                } footer: {
                    Text("Sends your paired watch's position to TAK while this iPhone is locked.", tableName: "PhoneLocationReporting")
                }
                if let advice = bridge.backgroundAdvice {
                    Section {
                        Label {
                            Text(advice)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        .font(.callout)
                        Button(String(localized: "Open Settings", table: "CompanionApp")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    } header: {
                        Text("Keep watch connected", tableName: "CompanionApp")
                    }
                }
                Section {
                    LabeledContent(String(localized: "Watch status", table: "CompanionApp"), value: bridge.isWatchPaired ? String(localized: "Paired", table: "CompanionApp") : String(localized: "Not paired", table: "CompanionApp"))
                    if let error = bridge.watchSetupError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    if let error = bridge.mapCacheError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
                Section(String(localized: "TAK Servers", table: "CompanionApp")) {
                    if bridge.adminLockEnabled {
                        Label("Server admin lock is on; configuration is read-only.", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if bridge.servers.isEmpty {
                        Text("No servers configured", tableName: "CompanionApp")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(bridge.servers.sorted {
                        let order = $0.displayName.localizedStandardCompare($1.displayName)
                        if order != .orderedSame { return order == .orderedAscending }
                        let hostOrder = $0.host.localizedStandardCompare($1.host)
                        return hostOrder == .orderedSame ? $0.port < $1.port : hostOrder == .orderedAscending
                    }) { server in
                        HStack(spacing: 12) {
                            Button { editor = ServerEditorRoute(server: server) } label: {
                                CompanionServerRowStatus(
                                    title: server.displayName,
                                    address: server.displayName == server.addressLabel ? nil : server.addressLabel,
                                    enabled: server.enabled,
                                    state: bridge.serverStates[server.id]
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(String(localized: bridge.adminLockEnabled ? "View server status for \(server.displayLabel)" : "Edit server \(server.displayLabel)", table: "CompanionApp"))
                            if server.enabled, bridge.serverStates[server.id]?.detail != "Connecting" {
                                Button { bridge.reconnect(id: server.id) } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(String(localized: "Reconnect \(server.displayLabel)", table: "CompanionApp"))
                            }
                            Toggle(String(localized: "Enable \(server.displayLabel)", table: "CompanionApp"), isOn: Binding(
                                get: { bridge.servers.first { $0.id == server.id }?.enabled ?? false },
                                set: { enabled in
                                    guard !bridge.adminLockEnabled else { return }
                                    do { try bridge.setEnabled(enabled, id: server.id) }
                                    catch { errorText = error.localizedDescription }
                                }
                            ))
                            .labelsHidden()
                            .disabled(bridge.adminLockEnabled)
                            if !bridge.adminLockEnabled {
                                Button(role: .destructive) {
                                    serverToRemove = server
                                    confirmRemove = true
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(String(localized: "Remove server \(server.displayLabel)", table: "CompanionApp"))
                            }
                        }
                    }
                    if !bridge.adminLockEnabled {
                        Button { editor = ServerEditorRoute(server: nil) } label: {
                            Label(String(localized: "Add Server", table: "CompanionApp"), systemImage: "plus")
                        }
                    }
                }
                Section {
                    NavigationLink {
                        CompanionSitxView(bridge: bridge, sitx: bridge.sitx)
                    } label: {
                        CompanionSitxRow(sitx: bridge.sitx)
                    }
                }
                Section {
                    Button {
                        showDeveloperModeEnabled = bridge.registerDeveloperModeTap()
                    } label: {
                        Text("Version \(appVersion)")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityHint("Tap seven times to enable developer mode.")
                    .alert("Developer mode enabled", isPresented: $showDeveloperModeEnabled) {
                        Button(String(localized: "OK", table: "CompanionApp"), role: .cancel) {}
                    }
                    if bridge.developerMode {
                        Toggle("Developer mode", isOn: $bridge.developerMode)
                        NavigationLink("Beta Features") {
                            CompanionBetaFeaturesView(bridge: bridge)
                        }
                    }
                }
            }
            .navigationTitle("WearTAK Companion")
            .sheet(item: $editor) { route in
                CompanionServerEditor(bridge: bridge, server: route.server)
            }
            .confirmationDialog(String(localized: "Remove server and its certificate?", table: "CompanionApp"), isPresented: $confirmRemove) {
                Button(String(localized: "Remove Server", table: "CompanionApp"), role: .destructive) {
                    guard !bridge.adminLockEnabled else { return }
                    do {
                        if let serverToRemove { try bridge.remove(id: serverToRemove.id) }
                    } catch { errorText = error.localizedDescription }
                }
            }
            .alert(String(localized: "Server settings", table: "CompanionApp"), isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button(String(localized: "OK", table: "CompanionApp"), role: .cancel) { errorText = nil }
            } message: { Text(errorText ?? "") }
            .onAppear { bridge.setActive(scenePhase == .active) }
            .onDisappear { bridge.resetDeveloperModeTaps() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { bridge.setActive(false) }
                else if phase == .active { bridge.setActive(true) }
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        return "\(version) (\(build))"
    }
}

private struct CompanionBetaFeaturesView: View {
    @ObservedObject var bridge: PhoneBridgeModel

    var body: some View {
        Form {
            Toggle("Lock server configuration", isOn: $bridge.adminLockEnabled)
            Text("When enabled, server and Sit(x) settings can be viewed but not changed. Reconnect and status information remain available.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .navigationTitle("Beta Features")
    }
}

/// Server row body: status dot, connection time or plain-language error and certificate expiry.
private struct CompanionServerRowStatus: View {
    let title: String
    let address: String?
    let enabled: Bool
    let state: PhoneBridgeModel.ServerState?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let status = CompanionServerStatus(enabled: enabled, connected: state?.connected == true,
                                               detail: state?.detail ?? "Disabled",
                                               connectedSince: state?.connectedSince, now: context.date)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(status.level.color).frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    Text(verbatim: title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .truncationMode(.middle)
                }
                if let address {
                    Text(verbatim: address)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(status.summary)
                    .font(.caption)
                    .foregroundStyle(status.level == .failed ? .red : .secondary)
                if enabled, let expires = state?.certificateExpires {
                    let certificate = CompanionServerStatus.certificateText(expires: expires, now: context.date)
                    HStack(spacing: 4) {
                        Image(systemName: certificate.warning ? "exclamationmark.triangle.fill" : "checkmark.seal")
                        Text(certificate.text)
                    }
                    .font(.caption2)
                    .foregroundStyle(certificate.warning ? .orange : .secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Full connection status for one server: the summary, the complete error text, the last error and certificate expiry.
private struct CompanionServerStatusSection: View {
    @ObservedObject var bridge: PhoneBridgeModel
    let serverID: UUID
    let enabled: Bool
    @State private var copied = false

    var body: some View {
        let state = bridge.serverStates[serverID]
        let now = Date()
        let status = CompanionServerStatus(enabled: enabled, connected: state?.connected == true,
                                           detail: state?.detail ?? "Disabled",
                                           connectedSince: state?.connectedSince, now: now)
        Section(String(localized: "Status", table: "CompanionApp")) {
            HStack(spacing: 8) {
                Circle().fill(status.level.color).frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(status.summary)
                    .foregroundStyle(status.level == .failed ? .red : .primary)
            }
            if let since = state?.connectedSince, state?.connected == true {
                LabeledContent(String(localized: "Connected since", table: "CompanionApp")) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(since.formatted(date: .abbreviated, time: .standard))
                        Text(since, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let detail = status.detail {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Error", tableName: "CompanionApp").font(.caption).foregroundStyle(.secondary)
                    Text(detail).font(.footnote.monospaced()).textSelection(.enabled)
                }
            }
            if let error = state?.lastError, let at = state?.lastErrorAt, error != status.detail {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last error · \(at.formatted(date: .abbreviated, time: .standard))", tableName: "CompanionApp")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(error).font(.footnote.monospaced()).textSelection(.enabled)
                }
            }
            if let expires = state?.certificateExpires {
                let certificate = CompanionServerStatus.certificateText(expires: expires, now: now)
                LabeledContent(String(localized: "Certificate", table: "CompanionApp")) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(expires.formatted(date: .abbreviated, time: .shortened))
                        if certificate.warning {
                            Text(certificate.text).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            if enabled, status.level != .connecting {
                Button { bridge.reconnect(id: serverID) } label: {
                    Label(String(localized: "Reconnect Now", table: "CompanionApp"), systemImage: "arrow.clockwise")
                }
            }
            Button {
                UIPasteboard.general.string = report(status: status, state: state, now: Date())
                copied = true
            } label: {
                Label(copied ? String(localized: "Copied", table: "CompanionApp") : String(localized: "Copy Details", table: "CompanionApp"), systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        }
    }

    /// Plain-text status report suitable for pasting into a chat or ticket.
    private func report(status: CompanionServerStatus, state: PhoneBridgeModel.ServerState?, now: Date) -> String {
        let server = bridge.servers.first { $0.id == serverID }
        var lines = ["WearTAK Companion server status"]
        if let server { lines.append("Server: \(server.displayLabel)") }
        lines.append("Status: \(status.summary)")
        if let since = state?.connectedSince, state?.connected == true {
            lines.append("Connected since: \(since.formatted(.iso8601))")
        }
        if let detail = status.detail { lines.append("Error: \(detail)") }
        if let error = state?.lastError, let at = state?.lastErrorAt {
            lines.append("Last error (\(at.formatted(.iso8601))): \(error)")
        }
        if let expires = state?.certificateExpires {
            lines.append("Certificate expires: \(expires.formatted(.iso8601))")
        }
        lines.append("Reported: \(now.formatted(.iso8601))")
        return lines.joined(separator: "\n")
    }
}

private extension CompanionServerStatus.Level {
    var color: Color {
        switch self {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .off: .gray
        }
    }
}

private struct ServerEditorRoute: Identifiable {
    let id = UUID()
    let server: CompanionServer?
}

private let enrollmentLogger = Logger(subsystem: "com.aegorsuch.weartak", category: "Enrollment")

private struct CompanionServerEditor: View {
    @ObservedObject var bridge: PhoneBridgeModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let original: CompanionServer?
    let serverID: UUID
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var enrollmentPort: String
    @AppStorage("WearTAK.bridge.deviceID") private var deviceID = ""
    @State private var username = ""
    @State private var password = ""
    @State private var p12Password = ""
    @State private var authentication = "Enroll"
    @State private var certificateStatus = String(localized: "Not configured", table: "CompanionApp")
    @State private var certificateReady = false
    @State private var busy = false
    @State private var enrollmentTask: Task<Void, Never>?
    @State private var showImporter = false
    @State private var trustedCA: Data?
    @State private var pendingIdentity: StoredIdentity?
    @State private var pendingEndpointKey: String?
    @State private var saved = false
    @State private var connectionError: String?

    init(bridge: PhoneBridgeModel, server: CompanionServer?) {
        self.bridge = bridge
        original = server
        serverID = server?.id ?? UUID()
        _name = State(initialValue: server?.name ?? "")
        _host = State(initialValue: server?.host ?? "")
        _port = State(initialValue: "\(server?.port ?? 8089)")
        _enrollmentPort = State(initialValue: "\(server?.enrollmentPort ?? 8446)")
    }

    private var connected: Bool { bridge.serverStates[serverID]?.connected == true }
    private var enabled: Bool { bridge.servers.first { $0.id == serverID }?.enabled ?? false }
    private var settingsLocked: Bool { bridge.adminLockEnabled || enabled || connected }

    var body: some View {
        NavigationStack {
            Form {
                TLSApprovalSection(bridge: bridge)
                Section {
                    LabeledContent(String(localized: "Server Name", table: "CompanionApp")) {
                        TextField(String(localized: "Optional", table: "CompanionApp"), text: $name)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                }
                .disabled(busy || bridge.adminLockEnabled)
                if original != nil {
                    Section {
                        Toggle(String(localized: "Server enabled", table: "CompanionApp"), isOn: Binding(
                            get: { enabled },
                            set: { value in
                                guard !bridge.adminLockEnabled else { return }
                                do { try bridge.setEnabled(value, id: serverID) }
                                catch { connectionError = error.localizedDescription }
                            }
                        ))
                        .disabled(busy || bridge.adminLockEnabled)
                    } footer: {
                        Text("Turn off Server enabled to edit the address or authentication. Save your changes before enabling again. This switch immediately changes the saved server; Cancel does not undo it.", tableName: "CompanionApp")
                    }
                }
                Section {
                    LabeledContent(String(localized: "IP or URL", table: "CompanionApp")) {
                        TextField("192.0.2.1", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent(String(localized: "Port", table: "CompanionApp")) {
                        TextField("8089", text: $port)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("TAK Server", tableName: "CompanionApp")
                } footer: {
                    if bridge.adminLockEnabled {
                        Label("Server admin lock is on.", systemImage: "lock.fill")
                    } else if settingsLocked {
                        Label(String(localized: "Disable server to edit", table: "CompanionApp"), systemImage: "lock.fill")
                    }
                }
                .disabled(busy || settingsLocked)
                Section {
                    if connected {
                        Label(String(localized: "Connected", table: "CompanionApp"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if certificateReady {
                        Label(String(localized: "Certificate ready", table: "CompanionApp"), systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        if pendingIdentity != nil {
                            Text("Save to finish setup", tableName: "CompanionApp")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Picker(String(localized: "Method", table: "CompanionApp"), selection: $authentication) {
                        Text("Enroll", tableName: "CompanionApp").tag("Enroll")
                        Text("Import .p12", tableName: "CompanionApp").tag("Import .p12")
                    }
                    .pickerStyle(.segmented)
                    if authentication == "Enroll" {
                        TextField(String(localized: "Username", table: "CompanionApp"), text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField(String(localized: "Password", table: "CompanionApp"), text: $password)
                            .textContentType(.password)
                        Button {
                            enroll()
                        } label: {
                            Label(busy ? String(localized: "Enrolling...", table: "CompanionApp") : String(localized: "Enroll Certificate", table: "CompanionApp"), systemImage: "person.badge.key.fill")
                        }
                        .disabled(busy || username.isEmpty || password.isEmpty || endpoint == nil)
                    } else {
                        SecureField(String(localized: "Certificate Password", table: "CompanionApp"), text: $p12Password)
                        Button {
                            showImporter = true
                        } label: {
                            Label(String(localized: "Import .p12", table: "CompanionApp"), systemImage: "square.and.arrow.down")
                        }
                        .disabled(busy || endpoint == nil)
                    }
                    LabeledContent(String(localized: "Certificate", table: "CompanionApp"), value: certificateStatus)
                } header: {
                    Text("Authentication", tableName: "CompanionApp")
                } footer: {
                    if bridge.adminLockEnabled {
                        Label("Server admin lock is on.", systemImage: "lock.fill")
                    } else if settingsLocked {
                        Label(String(localized: "Disable server to edit", table: "CompanionApp"), systemImage: "lock.fill")
                    }
                }
                .disabled(settingsLocked)
                if let original {
                    CompanionServerStatusSection(
                        bridge: bridge,
                        serverID: serverID,
                        enabled: bridge.servers.first { $0.id == serverID }?.enabled ?? original.enabled
                    )
                }
            }
            .navigationTitle(bridge.adminLockEnabled
                ? String(localized: "Server Status", table: "CompanionApp")
                : original == nil ? String(localized: "Add Server", table: "CompanionApp") : String(localized: "Edit Server", table: "CompanionApp"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", table: "CompanionApp")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save", table: "CompanionApp")) { save() }
                        .disabled(endpoint == nil || busy || bridge.adminLockEnabled)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
                importFile(result)
            }
            .alert(String(localized: "Server settings", table: "CompanionApp"), isPresented: Binding(
                get: { connectionError != nil },
                set: { if !$0 { connectionError = nil } }
            )) {
                Button(String(localized: "OK", table: "CompanionApp"), role: .cancel) { connectionError = nil }
            } message: {
                Text(connectionError ?? "")
            }
            .onAppear {
                if deviceID.isEmpty { deviceID = UUID().uuidString.lowercased() }
                refreshCertificate()
            }
            .onChange(of: host) { _, _ in resetChangedDraft(); refreshCertificate() }
            .onChange(of: port) { _, _ in resetChangedDraft(); refreshCertificate() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    if busy { enrollmentLogger.notice("Enrollment cancelled: Companion moved to background") }
                    enrollmentTask?.cancel()
                    password = ""
                    p12Password = ""
                } else if phase == .active {
                    refreshCertificate()
                }
            }
            .onDisappear {
                if busy { enrollmentLogger.notice("Enrollment cancelled: server editor closed") }
                enrollmentTask?.cancel()
                password = ""
                p12Password = ""
                if !saved, let pendingIdentity { CertificateStore.discardUncommitted(pendingIdentity) }
            }
        }
    }

    private var endpoint: CompanionEndpoint? {
        try? CompanionEndpoint.parse(address: host, streamPort: port, enrollmentPort: enrollmentPort)
    }

    private func refreshCertificate() {
        certificateReady = false
        guard let endpoint else { certificateStatus = String(localized: "Not configured", table: "CompanionApp"); return }
        trustedCA = UserDefaults.standard.data(forKey: "WearTAK.bridge.serverCA.\(endpoint.key)")
        do {
            guard let stored = try (pendingIdentity ?? CertificateStore.read(endpoint: endpoint.key)) else { certificateStatus = String(localized: "Not configured", table: "CompanionApp"); return }
            let identity = try CertificateStore.resolve(stored)
            certificateReady = true
            let expires = identity.expires.formatted(date: .abbreviated, time: .omitted)
            certificateStatus = identity.expires.timeIntervalSinceNow < 3 * 86_400
                ? String(localized: "Expires \(expires) - renew soon", table: "CompanionApp")
                : String(localized: "Expires \(expires)", table: "CompanionApp")
        } catch { certificateStatus = error.localizedDescription }
    }

    private func enroll() {
        guard !bridge.adminLockEnabled, let endpoint, !busy else { return }
        do { try validateUnique(endpoint) }
        catch { certificateStatus = error.localizedDescription; return }
        busy = true
        certificateStatus = String(localized: "Enrolling", table: "CompanionApp")
        let enrollmentUsername = username
        let enrollmentPassword = password
        enrollmentTask = Task {
            defer { busy = false; password = "" }
            do {
                let stored = try await EnrollmentClient.enroll(host: endpoint.host, port: endpoint.enrollmentPort,
                    username: enrollmentUsername, password: enrollmentPassword, deviceID: deviceID, trustedCA: trustedCA)
                do {
                    try Task.checkCancellation()
                    if let pendingIdentity { CertificateStore.discardUncommitted(pendingIdentity) }
                    pendingIdentity = stored
                    pendingEndpointKey = endpoint.key
                } catch {
                    CertificateStore.discardUncommitted(stored)
                    throw error
                }
                refreshCertificate()
            } catch is CancellationError {
                certificateStatus = String(localized: "Enrollment cancelled", table: "CompanionApp")
            } catch { certificateStatus = error.localizedDescription }
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        guard !bridge.adminLockEnabled else { return }
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 1_048_576 else { throw CompanionFailure.message(String(localized: "Choose a certificate file smaller than 1 MB.", table: "CompanionApp")) }
            let data = try Data(contentsOf: url)
            guard let endpoint else { throw CompanionFailure.message(String(localized: "Configure the server first.", table: "CompanionApp")) }
            try validateUnique(endpoint)
            let stored = try CertificateStore.importP12(data, password: p12Password)
            if let pendingIdentity { CertificateStore.discardUncommitted(pendingIdentity) }
            pendingIdentity = stored
            pendingEndpointKey = endpoint.key
            p12Password = ""
            refreshCertificate()
        } catch { certificateStatus = error.localizedDescription }
    }

    private func validateUnique(_ endpoint: CompanionEndpoint) throws {
        _ = try CompanionServer.saving(CompanionServer(id: serverID, endpoint: endpoint), into: bridge.servers)
    }

    private func resetChangedDraft() {
        if pendingEndpointKey != endpoint?.key, let pendingIdentity {
            CertificateStore.discardUncommitted(pendingIdentity)
            self.pendingIdentity = nil
            pendingEndpointKey = nil
        }
    }

    private func save() {
        guard !bridge.adminLockEnabled, let endpoint else { return }
        do {
            try validateUnique(endpoint)
            if let pendingIdentity {
                guard pendingEndpointKey == endpoint.key else { throw CompanionFailure.message(String(localized: "Enroll or import for this server again.", table: "CompanionApp")) }
                try CertificateStore.save(pendingIdentity, endpoint: endpoint.key)
            }
            let current = bridge.servers.first { $0.id == serverID }
            let sameEndpoint = current?.endpoint.key == endpoint.key
            let record = CompanionServer(id: serverID, endpoint: endpoint, enabled: original == nil ? true : enabled,
                                         streamTLSName: sameEndpoint ? current?.streamTLSName : nil,
                                         apiTLSName: sameEndpoint ? current?.apiTLSName : nil, name: name)
            try bridge.save(record)
            saved = true
            dismiss()
        } catch { certificateStatus = error.localizedDescription }
    }
}

private struct TLSApprovalSection: View {
    @ObservedObject var bridge: PhoneBridgeModel

    var body: some View {
        if let error = bridge.tlsDiscoveryError {
            Section(String(localized: "Certificate discovery", table: "CompanionApp")) {
                Text(error).foregroundStyle(.orange)
            }
        }
    }
}

private struct CompanionSitxRow: View {
    @ObservedObject var sitx: CompanionSitxSession

    var body: some View {
        Text("Sit(x) TAK")
    }
}

/// Same menu as the watch: Sit(x) TAK toggle, Address, Group, Sit(x) State, Re-auth.
private struct CompanionSitxView: View {
    @ObservedObject var bridge: PhoneBridgeModel
    @ObservedObject var sitx: CompanionSitxSession
    @State private var showAuthorization = false
    @State private var confirmRemoval = false
    @State private var removing = false

    var body: some View {
        List {
            Toggle("Sit(x) TAK", isOn: Binding(get: { sitx.enabled }, set: {
                guard !bridge.adminLockEnabled else { return }
                sitx.setEnabled($0)
            }))
            .disabled(bridge.adminLockEnabled)
            NavigationLink {
                CompanionSitxAddressView(bridge: bridge, sitx: sitx)
            } label: {
                LabeledContent(String(localized: "Address", table: "CompanionApp"), value: sitx.host.isEmpty ? String(localized: "Not set", table: "CompanionApp") : SitxAPI.displayHost(sitx.host))
            }
            .disabled(bridge.adminLockEnabled)
            NavigationLink {
                List(sitx.groups) { group in
                    Button {
                        guard !bridge.adminLockEnabled else { return }
                        sitx.selectGroup(group)
                    } label: {
                        HStack {
                            Text(group.name).foregroundStyle(.primary)
                            Spacer()
                            if sitx.selectedFlowTag == group.id { Image(systemName: "checkmark") }
                        }
                    }
                }
                .navigationTitle(String(localized: "Group", table: "CompanionApp"))
                .refreshable { sitx.refreshGroups() }
            } label: {
                LabeledContent(String(localized: "Group", table: "CompanionApp"), value: sitx.selectedGroupName ?? String(localized: "Not selected", table: "CompanionApp"))
            }
            .disabled(bridge.adminLockEnabled || sitx.groups.isEmpty || !sitx.enabled)
            LabeledContent(String(localized: "Sit(x) State", table: "CompanionApp")) {
                Text(sitx.state.detail).multilineTextAlignment(.trailing)
            }
            if !sitx.host.isEmpty {
                LabeledContent(String(localized: "Linked Account", table: "CompanionApp")) {
                    Text(SitxLinkedAccount.displayLabel(sitx.hasAuthorization ? sitx.linkedAccount : nil))
                        .multilineTextAlignment(.trailing).textSelection(.enabled)
                }
            }
            let reauthDisabled = bridge.adminLockEnabled || !sitx.enabled || sitx.host.isEmpty || (sitx.hasAuthorization && sitx.state.connected)
            Button {
                guard !reauthDisabled else { return }
                sitx.reauthorize()
            } label: {
                Label(String(localized: "Re-auth", table: "CompanionApp"), systemImage: "arrow.clockwise")
                    .foregroundStyle(reauthDisabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
            }
            .disabled(reauthDisabled)
            Button(String(localized: "Remove Sit(x) connection", table: "CompanionApp"), role: .destructive) { confirmRemoval = true }
                .disabled(removing || bridge.adminLockEnabled)
        }
        .navigationTitle("Sit(x) TAK")
        .confirmationDialog(String(localized: "Remove Sit(x) connection and all saved authorization, address and groups?", table: "CompanionApp"), isPresented: $confirmRemoval) {
            Button(String(localized: "Remove Sit(x) connection", table: "CompanionApp"), role: .destructive) {
                guard !bridge.adminLockEnabled else { return }
                removing = true
                Task {
                    await sitx.removeConnection()
                    removing = false
                }
            }
        }
        .disabled(removing)
        .onAppear {
            showAuthorization = !sitx.authorizationCode.isEmpty
            if sitx.enabled, sitx.hasAuthorization, sitx.groups.count <= 1 { sitx.refreshGroups() }
        }
        .onChange(of: sitx.authorizationCode) { _, code in showAuthorization = !code.isEmpty }
        .sheet(isPresented: $showAuthorization) {
            NavigationStack {
                List {
                    LabeledContent(String(localized: "Auth Code", table: "CompanionApp")) {
                        Text(sitx.authorizationCode).font(.title3.monospaced()).textSelection(.enabled)
                    }
                    Button {
                        UIPasteboard.general.string = sitx.authorizationCode
                    } label: {
                        Label(String(localized: "Copy Code", table: "CompanionApp"), systemImage: "doc.on.doc")
                    }
                    if let url = URL(string: sitx.verificationURL), !sitx.verificationURL.isEmpty {
                        Link(destination: url) {
                            Label(String(localized: "Authorize", table: "CompanionApp"), systemImage: "arrow.up.right.square")
                        }
                        .disabled(bridge.adminLockEnabled)
                    }
                    Text(sitx.state.detail).foregroundStyle(.secondary)
                }
                .navigationTitle(String(localized: "Authorization", table: "CompanionApp"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Back", table: "CompanionApp")) { showAuthorization = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct CompanionSitxAddressView: View {
    @ObservedObject var bridge: PhoneBridgeModel
    @ObservedObject var sitx: CompanionSitxSession
    @Environment(\.dismiss) private var dismiss
    @State private var address: String

    init(bridge: PhoneBridgeModel, sitx: CompanionSitxSession) {
        self.bridge = bridge
        self.sitx = sitx
        _address = State(initialValue: SitxAPI.organization(sitx.host))
    }

    var body: some View {
        List {
            TextField(String(localized: "Organization", table: "CompanionApp"), text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(saveAddress)
                .disabled(bridge.adminLockEnabled)
            Text(SitxAPI.normalizedHost(address).map(SitxAPI.displayHost) ?? ".sitx.io")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: saveAddress) {
                Label(String(localized: "Save", table: "CompanionApp"), systemImage: "checkmark")
            }
            .disabled(bridge.adminLockEnabled || SitxAPI.normalizedHost(address) == nil)
        }
        .navigationTitle(String(localized: "Address", table: "CompanionApp"))
    }

    private func saveAddress() {
        guard !bridge.adminLockEnabled, let host = SitxAPI.normalizedHost(address) else { return }
        sitx.setAddress(host)
        dismiss()
    }
}
