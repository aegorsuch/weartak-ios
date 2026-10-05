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
                Section {
                    LabeledContent("Watch status", value: bridge.isWatchPaired ? "Paired" : "Not paired")
                    if let error = bridge.watchSetupError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    if let error = bridge.mapCacheError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("TAK Servers") {
                    if bridge.servers.isEmpty {
                        Text("No servers configured")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(bridge.servers) { server in
                        HStack(spacing: 12) {
                            Button { editor = ServerEditorRoute(server: server) } label: {
                                CompanionServerRowStatus(
                                    title: "\(server.host):\(server.port)",
                                    enabled: server.enabled,
                                    state: bridge.serverStates[server.id]
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit server \(server.host)")
                            if server.enabled, bridge.serverStates[server.id]?.detail != "Connecting" {
                                Button { bridge.reconnect(id: server.id) } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Reconnect \(server.host)")
                            }
                            Toggle("Enable \(server.host)", isOn: Binding(
                                get: { bridge.servers.first { $0.id == server.id }?.enabled ?? false },
                                set: { enabled in
                                    do { try bridge.setEnabled(enabled, id: server.id) }
                                    catch { errorText = error.localizedDescription }
                                }
                            ))
                            .labelsHidden()
                            Button(role: .destructive) {
                                serverToRemove = server
                                confirmRemove = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove server \(server.host)")
                        }
                    }
                    Button { editor = ServerEditorRoute(server: nil) } label: {
                        Label("Add Server", systemImage: "plus")
                    }
                }
                Section {
                    NavigationLink {
                        CompanionSitxView(sitx: bridge.sitx)
                    } label: {
                        CompanionSitxRow(sitx: bridge.sitx)
                    }
                } footer: {
                    Text("Set up here or on the watch. Companion holds the Sit(x) connection because watchOS blocks direct streaming on Apple Watch.")
                }
            }
            .navigationTitle("WearTAK Companion")
            .sheet(item: $editor) { route in
                CompanionServerEditor(bridge: bridge, server: route.server)
            }
            .confirmationDialog("Remove server and its certificate?", isPresented: $confirmRemove) {
                Button("Remove Server", role: .destructive) {
                    do {
                        if let serverToRemove { try bridge.remove(id: serverToRemove.id) }
                    } catch { errorText = error.localizedDescription }
                }
            }
            .alert("Server settings", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) { errorText = nil }
            } message: { Text(errorText ?? "") }
            .onAppear { bridge.setActive(scenePhase == .active) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { bridge.setActive(false) }
                else if phase == .active { bridge.setActive(true) }
            }
        }
    }
}

/// Server row body: status dot, connection time or plain-language error and certificate expiry.
private struct CompanionServerRowStatus: View {
    let title: String
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
        Section("Status") {
            HStack(spacing: 8) {
                Circle().fill(status.level.color).frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(status.summary)
                    .foregroundStyle(status.level == .failed ? .red : .primary)
            }
            if let since = state?.connectedSince, state?.connected == true {
                LabeledContent("Connected since") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(since.formatted(date: .abbreviated, time: .standard))
                        Text(since, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let detail = status.detail {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Error").font(.caption).foregroundStyle(.secondary)
                    Text(detail).font(.footnote.monospaced()).textSelection(.enabled)
                }
            }
            if let error = state?.lastError, let at = state?.lastErrorAt, error != status.detail {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last error · \(at.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(error).font(.footnote.monospaced()).textSelection(.enabled)
                }
            }
            if let expires = state?.certificateExpires {
                let certificate = CompanionServerStatus.certificateText(expires: expires, now: now)
                LabeledContent("Certificate") {
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
                    Label("Reconnect Now", systemImage: "arrow.clockwise")
                }
            }
            Button {
                UIPasteboard.general.string = report(status: status, state: state, now: Date())
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy Details", systemImage: copied ? "checkmark" : "doc.on.doc")
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
        if let server { lines.append("Server: \(server.host):\(server.port)") }
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

private struct CompanionServerEditor: View {
    @ObservedObject var bridge: PhoneBridgeModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let original: CompanionServer?
    let serverID: UUID
    @State private var host: String
    @State private var port: String
    @State private var enrollmentPort: String
    @State private var streamTLSName: String
    @AppStorage("WearTAK.bridge.deviceID") private var deviceID = ""
    @State private var username = ""
    @State private var password = ""
    @State private var p12Password = ""
    @State private var authentication = "Enroll"
    @State private var certificateStatus = "Not configured"
    @State private var certificateReady = false
    @State private var busy = false
    @State private var enrollmentTask: Task<Void, Never>?
    @State private var showImporter = false
    @State private var trustedCA: Data?
    @State private var pendingIdentity: StoredIdentity?
    @State private var pendingEndpointKey: String?
    @State private var saved = false

    init(bridge: PhoneBridgeModel, server: CompanionServer?) {
        self.bridge = bridge
        original = server
        serverID = server?.id ?? UUID()
        _host = State(initialValue: server?.host ?? "")
        _port = State(initialValue: "\(server?.port ?? 8089)")
        _enrollmentPort = State(initialValue: "\(server?.enrollmentPort ?? 8446)")
        _streamTLSName = State(initialValue: server?.streamTLSName ?? "")
    }

    private var connected: Bool { bridge.serverStates[serverID]?.connected == true }

    var body: some View {
        NavigationStack {
            Form {
                Section("TAK Server") {
                    LabeledContent("IP or URL") {
                        TextField("192.0.2.1", text: $host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Port") {
                        TextField("8089", text: $port)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .disabled(busy || connected)
                Section("Advanced TLS identity") {
                    TextField("Stream TLS name (optional)", text: $streamTLSName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                .disabled(busy || connected)
                Section("Authentication") {
                    if connected {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if certificateReady {
                        Label("Certificate ready", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        if pendingIdentity != nil {
                            Text("Save to finish setup")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Picker("Method", selection: $authentication) {
                        Text("Enroll").tag("Enroll")
                        Text("Import .p12").tag("Import .p12")
                    }
                    .pickerStyle(.segmented)
                    if authentication == "Enroll" {
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                        Button {
                            enroll()
                        } label: {
                            Label(busy ? "Enrolling..." : "Enroll Certificate", systemImage: "person.badge.key.fill")
                        }
                        .disabled(busy || username.isEmpty || password.isEmpty || endpoint == nil)
                    } else {
                        SecureField("Certificate Password", text: $p12Password)
                        Button {
                            showImporter = true
                        } label: {
                            Label("Import .p12", systemImage: "square.and.arrow.down")
                        }
                        .disabled(busy || endpoint == nil)
                    }
                    LabeledContent("Certificate", value: certificateStatus)
                }
                .disabled(connected)
                if let original {
                    CompanionServerStatusSection(
                        bridge: bridge,
                        serverID: serverID,
                        enabled: bridge.servers.first { $0.id == serverID }?.enabled ?? original.enabled
                    )
                }
            }
            .navigationTitle(original == nil ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(endpoint == nil || busy)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data]) { result in
                importFile(result)
            }
            .onAppear {
                if deviceID.isEmpty { deviceID = UUID().uuidString.lowercased() }
                refreshCertificate()
            }
            .onChange(of: host) { _, _ in resetChangedDraft(); refreshCertificate() }
            .onChange(of: port) { _, _ in resetChangedDraft(); refreshCertificate() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    enrollmentTask?.cancel()
                    password = ""
                    p12Password = ""
                } else if phase == .active {
                    refreshCertificate()
                }
            }
            .onDisappear {
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
        guard let endpoint else { certificateStatus = "Not configured"; return }
        trustedCA = UserDefaults.standard.data(forKey: "WearTAK.bridge.serverCA.\(endpoint.key)")
        do {
            guard let stored = try (pendingIdentity ?? CertificateStore.read(endpoint: endpoint.key)) else { certificateStatus = "Not configured"; return }
            let identity = try CertificateStore.resolve(stored)
            certificateReady = true
            certificateStatus = "Expires " + identity.expires.formatted(date: .abbreviated, time: .omitted)
            if identity.expires.timeIntervalSinceNow < 3 * 86_400 { certificateStatus += " - renew soon" }
        } catch { certificateStatus = error.localizedDescription }
    }

    private func enroll() {
        guard let endpoint, !busy else { return }
        do { try validateUnique(endpoint) }
        catch { certificateStatus = error.localizedDescription; return }
        busy = true
        certificateStatus = "Enrolling"
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
                certificateStatus = "Enrollment cancelled"
            } catch { certificateStatus = error.localizedDescription }
        }
    }

    private func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 1_048_576 else { throw CompanionFailure.message("Choose a certificate file smaller than 1 MB.") }
            let data = try Data(contentsOf: url)
            guard let endpoint else { throw CompanionFailure.message("Configure the server first.") }
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
        guard let endpoint else { return }
        do {
            try validateUnique(endpoint)
            let tlsName = try CompanionServer.validatedStreamTLSName(streamTLSName)
            if let pendingIdentity {
                guard pendingEndpointKey == endpoint.key else { throw CompanionFailure.message("Enroll or import for this server again.") }
                try CertificateStore.save(pendingIdentity, endpoint: endpoint.key)
            }
            let record = CompanionServer(id: serverID, endpoint: endpoint, enabled: original?.enabled ?? false,
                                         streamTLSName: tlsName)
            try bridge.save(record)
            saved = true
            dismiss()
        } catch { certificateStatus = error.localizedDescription }
    }
}

private struct CompanionSitxRow: View {
    @ObservedObject var sitx: CompanionSitxSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Sit(x) TAK")
            Text(sitx.state.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Same menu as the watch: Sit(x) TAK toggle, Address, Group, Sit(x) State, Re-auth.
private struct CompanionSitxView: View {
    @ObservedObject var sitx: CompanionSitxSession
    @State private var showAuthorization = false

    var body: some View {
        List {
            Toggle("Sit(x) TAK", isOn: Binding(get: { sitx.enabled }, set: { sitx.setEnabled($0) }))
            NavigationLink {
                CompanionSitxAddressView(sitx: sitx)
            } label: {
                LabeledContent("Address", value: sitx.host.isEmpty ? "Not set" : SitxAPI.displayHost(sitx.host))
            }
            NavigationLink {
                List(sitx.groups) { group in
                    Button {
                        sitx.selectGroup(group)
                    } label: {
                        HStack {
                            Text(group.name).foregroundStyle(.primary)
                            Spacer()
                            if sitx.selectedFlowTag == group.id { Image(systemName: "checkmark") }
                        }
                    }
                }
                .navigationTitle("Group")
                .refreshable { sitx.refreshGroups() }
            } label: {
                LabeledContent("Group", value: sitx.selectedGroupName ?? "Not selected")
            }
            .disabled(sitx.groups.isEmpty || !sitx.enabled)
            LabeledContent("Sit(x) State") {
                Text(sitx.state.detail).multilineTextAlignment(.trailing)
            }
            Button {
                sitx.reauthorize()
            } label: {
                Label("Re-auth", systemImage: "arrow.clockwise")
            }
            .disabled(!sitx.enabled || sitx.host.isEmpty)
        }
        .navigationTitle("Sit(x) TAK")
        .onAppear {
            showAuthorization = !sitx.authorizationCode.isEmpty
            if sitx.enabled, sitx.hasAuthorization, sitx.groups.count <= 1 { sitx.refreshGroups() }
        }
        .onChange(of: sitx.authorizationCode) { _, code in showAuthorization = !code.isEmpty }
        .sheet(isPresented: $showAuthorization) {
            NavigationStack {
                List {
                    LabeledContent("Auth Code") {
                        Text(sitx.authorizationCode).font(.title3.monospaced()).textSelection(.enabled)
                    }
                    Button {
                        UIPasteboard.general.string = sitx.authorizationCode
                    } label: {
                        Label("Copy Code", systemImage: "doc.on.doc")
                    }
                    if let url = URL(string: sitx.verificationURL), !sitx.verificationURL.isEmpty {
                        Link(destination: url) {
                            Label("Authorize", systemImage: "arrow.up.right.square")
                        }
                    }
                    Text(sitx.state.detail).foregroundStyle(.secondary)
                }
                .navigationTitle("Authorization")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back") { showAuthorization = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct CompanionSitxAddressView: View {
    @ObservedObject var sitx: CompanionSitxSession
    @Environment(\.dismiss) private var dismiss
    @State private var address: String

    init(sitx: CompanionSitxSession) {
        self.sitx = sitx
        _address = State(initialValue: SitxAPI.organization(sitx.host))
    }

    var body: some View {
        List {
            TextField("Organization", text: $address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(saveAddress)
            Text(SitxAPI.normalizedHost(address).map(SitxAPI.displayHost) ?? ".sitx.io")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: saveAddress) {
                Label("Save", systemImage: "checkmark")
            }
            .disabled(SitxAPI.normalizedHost(address) == nil)
        }
        .navigationTitle("Address")
    }

    private func saveAddress() {
        guard let host = SitxAPI.normalizedHost(address) else { return }
        sitx.setAddress(host)
        dismiss()
    }
}
