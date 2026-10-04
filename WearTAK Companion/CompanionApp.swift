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
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: "\(server.host):\(server.port)")
                                        .foregroundStyle(.primary)
                                    Text(bridge.serverStates[server.id]?.detail ?? "Disabled")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit server \(server.host)")
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