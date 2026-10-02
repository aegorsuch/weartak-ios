import CoreLocation
import MapKit
import SwiftUI
import WatchKit

struct ContentView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var physiology: PhysiologyMonitor
    @ObservedObject var environment: EnvironmentalMonitor
    @ObservedObject var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPointTypePicker = false
    @State private var showMapPreview = false
    @State private var toastMessage: String?

    var body: some View {
        NavigationStack {
            WatchDashboardView(
                model: model,
                physiology: physiology,
                environment: environment,
                settings: settings,
                dropPoint: {
                    model.requestLocation()
                    showPointTypePicker = true
                }
            )
            .navigationDestination(isPresented: $showMapPreview) {
                TacticalMapView(model: model, settings: settings)
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    Text(toastMessage)
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .sheet(isPresented: $showPointTypePicker) {
            NavigationStack {
                PointTypePickerView(model: model) { kind in
                    guard let coordinate = model.lastLocation?.coordinate else {
                        model.requestLocation()
                        return false
                    }
                    guard model.addMarker(at: coordinate, kind: kind, title: model.defaultPointTitle(), remark: "") else { return false }
                    showToast("\(kind.rawValue) point dropped")
                    return true
                }
            }
        }
        .task {
            model.setAppActive(true)
            model.requestLocation()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-point-picker") {
                showPointTypePicker = true
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-map-filters") {
                model.receiveEntity(EntityRelayPayload(uid: "preview-alpha", lat: 41.8801, lon: -87.6410, type: "a-f-G-U-C", callSign: "ALPHA", team: "Red", role: "Team Lead"))
                model.receiveEntity(EntityRelayPayload(uid: "preview-bravo", lat: 41.8802, lon: -87.6412, type: "a-f-G-U-C", callSign: "BRAVO", team: "Red", role: "Team Lead"))
                model.receiveEntity(EntityRelayPayload(uid: "preview-charlie", lat: 41.8803, lon: -87.6414, type: "a-f-G-U-C", callSign: "CHARLIE", team: "Green", role: "Team Member"))
                showMapPreview = true
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-map") {
                showMapPreview = true
            }
            #endif
            if settings.physiologicalAlertsEnabled {
                await physiology.startMonitoring()
            }
            if settings.environmentalAlertsEnabled {
                environment.startMonitoring()
            }
        }
        .onChange(of: physiology.activeAutomaticAlert) { _, category in
            model.updateAutomaticAlert(category)
        }
        .onChange(of: settings.physiologicalAlertsEnabled) { _, enabled in
            if enabled {
                Task { await physiology.startMonitoring() }
            } else {
                physiology.stopMonitoring()
            }
        }
        .onChange(of: settings.physiologicalMonitoringEnabled) { _, enabled in
            if enabled && scenePhase == .active {
                Task { await physiology.startMonitoring() }
            } else if !enabled {
                physiology.stopSensing()
            }
        }
        .onChange(of: settings.environmentalAlertsEnabled) { _, enabled in
            if enabled && scenePhase == .active {
                environment.startMonitoring()
            } else if !enabled {
                environment.stopMonitoring()
            }
        }
        .onChange(of: environment.activePressureCategory) { oldValue, newValue in
            if let oldValue, oldValue != newValue {
                model.setEnvironmentalAlert(oldValue, active: false)
            }
            if let newValue {
                model.setEnvironmentalAlert(newValue, active: true)
            }
        }
        .onChange(of: environment.immersionActive) { _, active in
            model.setEnvironmentalAlert(.immersion, active: active)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                model.setAppActive(false)
                physiology.stopViewing()
                physiology.stopMonitoring()
                environment.stopMonitoring()
            } else if phase == .active {
                model.setAppActive(true)
                if settings.physiologicalAlertsEnabled {
                    Task { await physiology.startMonitoring() }
                } else if physiology.isViewing {
                    Task { await physiology.startViewing() }
                }
                if settings.environmentalAlertsEnabled {
                    environment.startMonitoring()
                }
            }
        }
    }

    private func showToast(_ message: String) {
        withAnimation { toastMessage = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toastMessage = nil }
        }
    }
}

private struct WatchDashboardView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var physiology: PhysiologyMonitor
    @ObservedObject var environment: EnvironmentalMonitor
    @ObservedObject var settings: AppSettings
    let dropPoint: () -> Void

    private let accent = Color(red: 0.67, green: 0.80, blue: 0.98)

    var body: some View {
        GeometryReader { geometry in
            let small = geometry.size.height < 180
            let spacing = min(12, max(6, geometry.size.height * 0.04))
            let rowHeight = max(0, geometry.size.height - 20 - spacing * 3)
            ScrollView {
                VStack(spacing: spacing) {
                    statusHeader(small: small)
                        .frame(height: rowHeight * 0.26)
                    actionRow
                        .frame(height: rowHeight * 0.30)
                    shortcutRow(small: small)
                        .frame(height: rowHeight * 0.20)
                    navigationRow(small: small)
                        .frame(height: rowHeight * 0.24)
                }
                .padding(.horizontal, 4)
                .padding(.top, 4)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
        }
        .background(.black)
        .ignoresSafeArea(.container, edges: .bottom)
        .buttonStyle(.plain)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
            model.startHeadingUpdates()
            await physiology.startViewing()
        }
        .onDisappear {
            model.stopHeadingUpdates()
            physiology.stopViewing()
        }
    }

    private var physiologyBorderColor: Color {
        switch DashboardPhysiologySeverity.resolve(
            warningActive: physiology.warningCategory != nil,
            alertActive: physiology.activeAutomaticAlert != nil
        ) {
        case .normal: return .clear
        case .warning: return .yellow
        case .alert: return .red
        }
    }

    private func statusHeader(small: Bool) -> some View {
        HStack(spacing: 6) {
            VStack(spacing: small ? 2 : 3) {
                DashboardTAKIndicator(model: model, settings: settings)
                    .frame(width: 28, height: small ? 20 : 24)
                NavigationLink {
                    NetworkPreferencesView(model: model, settings: settings, sitxClient: model.sitxClient)
                } label: {
                    Image(systemName: model.networkConnectivity.symbol)
                        .font(.system(size: small ? 12 : 15, weight: .semibold))
                        .frame(width: 28, height: small ? 12 : 16)
                }
                .accessibilityLabel("Network preferences: \(model.networkConnectivity.rawValue)")
            }
            Spacer(minLength: 0)
            NavigationLink {
                DashboardMetricPreferencesView(settings: settings, monitor: physiology)
            } label: {
                VStack(spacing: 2) {
                    Text(settings.dashboardMetric.rawValue)
                        .font(.system(size: small ? 10 : 12))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Image(systemName: settings.dashboardMetric.symbol)
                            .font(.system(size: 16))
                            .foregroundStyle(accent)
                            Text(settings.dashboardMetric == .exertion
                                ? physiology.exertionPercent.map { "\($0)%" } ?? "--%"
                                : physiology.heartRate.map { "\($0)" } ?? "--")
                            .font(.system(size: small ? 21 : 24, weight: .semibold))
                            .monospacedDigit()
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(physiologyBorderColor, lineWidth: 2))
            }
            .accessibilityLabel(settings.dashboardMetric == .exertion
                ? "Select metric. Exertion \(physiology.exertionPercent.map { "\($0) percent" } ?? "unavailable")"
                : "Select metric. Heart rate \(physiology.heartRate.map { "\($0) beats per minute" } ?? "unavailable")")
            Spacer(minLength: 0)
            VStack(spacing: small ? 2 : 3) {
                Button { model.requestLocation() } label: {
                    Image(systemName: "location.fill")
                        .font(.system(size: small ? 18 : 20))
                        .foregroundStyle(model.lastLocation == nil ? .gray : .white)
                        .frame(width: 28, height: small ? 20 : 24)
                }
                .accessibilityLabel("Refresh location")
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    let battery = WKInterfaceDevice.current().batteryLevel
                    Image(systemName: battery < 0 ? "battery.0percent" : battery < 0.25 ? "battery.25percent" : battery < 0.5 ? "battery.50percent" : battery < 0.75 ? "battery.75percent" : "battery.100percent")
                        .font(.system(size: small ? 11 : 14))
                        .foregroundStyle(battery >= 0 && battery < 0.25 ? .red : .white)
                        .accessibilityLabel(battery < 0 ? "Battery unavailable" : "Battery \(Int(battery * 100)) percent")
                }
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            NavigationLink {
                ManualAlertView(model: model)
            } label: {
                outlinedControl("exclamationmark.triangle", color: .red)
                    .background(model.activeAlertType == nil ? Color.clear : Color.red, in: Capsule())
            }
            .accessibilityLabel(model.activeAlertType.map { "Manual alert active: \($0.rawValue)" } ?? "Manual alert")
            Button(action: dropPoint) {
                PointDropSymbol()
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                    .frame(width: 31, height: 34)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(Capsule().stroke(.white, lineWidth: 3))
            }
            .accessibilityLabel("Drop 2525D point")
        }
    }

    private func shortcutRow(small: Bool) -> some View {
        HStack(spacing: 10) {
            if settings.chatEnabled {
                NavigationLink {
                    ChatView(model: model, settings: settings)
                } label: {
                    roundControl("message.fill", color: accent, size: small ? 28 : 34)
                }
                .accessibilityLabel("Chat")
            }
            NavigationLink {
                SettingsView(model: model, settings: settings)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.system(size: small ? 19 : 22))
                    Text(settings.callSign)
                        .font(.system(size: small ? 12 : 14))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(Capsule().stroke(.gray, lineWidth: 1.5))
            }
            .accessibilityLabel("Settings\(settings.callSign.isEmpty ? "" : ", \(settings.callSign)")")
        }
    }

    private func navigationRow(small: Bool) -> some View {
        HStack(spacing: 8) {
            NavigationLink {
                BloodhoundView(model: model)
            } label: {
                HStack(spacing: 6) {
                    let reading = model.lastLocation.flatMap { model.bloodhoundCompassReading(from: $0) }
                    let hasTarget = model.bloodhoundTarget != nil
                    let northRotation = model.headingDegrees.map { (360 - $0).truncatingRemainder(dividingBy: 360) } ?? 0
                    let hasHeading = hasTarget ? reading?.isCompassRelative == true : model.headingDegrees != nil
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 19))
                        .rotationEffect(.degrees(hasTarget ? reading?.relativeBearingDegrees ?? 0 : northRotation))
                        .foregroundStyle(hasHeading ? .red : .gray)
                        .frame(width: small ? 28 : 32, height: small ? 28 : 32)
                        .overlay(Circle().stroke(.gray, lineWidth: 2))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.bloodhoundTarget?.displayTitle ?? "Compass")
                            .font(.system(size: small ? 10 : 11, weight: .medium))
                            .lineLimit(1)
                        Text(reading.map { "\(Int($0.rangeMeters)) m" } ?? "___")
                            .font(.system(size: small ? 13 : 15, weight: .semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 0)
                }
            }
            .accessibilityLabel(model.bloodhoundTarget == nil ? "Compass" : "Bloodhound navigation")
            NavigationLink {
                TacticalMapView(model: model, settings: settings)
            } label: {
                roundControl("map", color: Color(red: 0.81, green: 0.81, blue: 0.73), size: small ? 28 : 34)
            }
            .accessibilityLabel("Map")
        }
    }

    private func outlinedControl(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 30, weight: .regular))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(Capsule().stroke(color, lineWidth: 3))
    }

    private func roundControl(_ symbol: String, color: Color, size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(Color(white: 0.22), in: Circle())
    }
}

private struct DashboardMetricPreferencesView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var monitor: PhysiologyMonitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Toggle(isOn: $settings.physiologicalAlertsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Physiological Alerts")
                    Text(settings.physiologicalAlertsEnabled ? "On" : "Off")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Display") {
                ForEach(DashboardMetric.allCases) { metric in
                    Button {
                        settings.dashboardMetric = metric
                        dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Label(metric.rawValue, systemImage: metric.symbol)
                                .font(.caption)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer()
                            Text(reading(for: metric))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            if settings.dashboardMetric == metric {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Metric")
        .task { await monitor.startViewing() }
        .onDisappear { monitor.stopViewing() }
    }

    private func reading(for metric: DashboardMetric) -> String {
        switch metric {
        case .exertion:
            return monitor.exertionPercent.map { "\($0)%" } ?? "Unavailable"
        case .heartRate:
            return monitor.heartRate.map { "\($0) BPM" } ?? "Unavailable"
        }
    }
}

private struct DashboardTAKIndicator: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var sitx: SitxClient
    @ObservedObject var multicast: MulticastTAKTransport

    init(model: WatchSessionModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        sitx = model.sitxClient
        multicast = model.multicastClient
    }

    var body: some View {
        let state = DashboardTAKStatus.resolve(
            multicastReady: multicast.isReady,
            sitxConnected: sitx.isSitxConnected,
            phoneRelayConnected: model.isPhoneRelayConnected,
            multicastEnabled: settings.multicastEnabled,
            sitxEnabled: settings.sitxEnabled,
            relaySelected: settings.relayProvider != .notSet
        )
        NavigationLink {
            NetworkPreferencesView(model: model, settings: settings, sitxClient: sitx)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                HStack(spacing: 0) {
                    if state.displayed.isEmpty {
                        Image(systemName: "network")
                            .frame(width: 24)
                    } else {
                        ForEach(state.displayed, id: \.self) { output in
                            Image(systemName: output.symbol)
                                .frame(width: CGFloat(24 / state.displayed.count))
                        }
                    }
                }
                .font(.system(size: state.displayed.count > 2 ? 8 : state.displayed.count > 1 ? 11 : 19))
                .foregroundStyle(state.isConnected ? Color(red: 0.67, green: 0.80, blue: 0.98) : .gray)
                Image(systemName: state.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(state.isConnected ? .green : .orange)
                    .background(.black, in: Circle())
                    .offset(x: 3, y: 2)
            }
        }
        .accessibilityLabel(state.label + ". Network preferences")
    }
}

private struct PointDropSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        var path = Path()
        path.move(to: CGPoint(x: width * 0.63, y: height * 0.82))
        path.addLine(to: CGPoint(x: width * 0.5, y: height * 0.99))
        path.addCurve(to: CGPoint(x: width * 0.04, y: height * 0.36),
                      control1: CGPoint(x: width * 0.33, y: height * 0.8),
                      control2: CGPoint(x: width * 0.04, y: height * 0.53))
        path.addCurve(to: CGPoint(x: width * 0.5, y: height * 0.02),
                      control1: CGPoint(x: width * 0.04, y: height * 0.17),
                      control2: CGPoint(x: width * 0.24, y: height * 0.02))
        path.addCurve(to: CGPoint(x: width * 0.96, y: height * 0.36),
                      control1: CGPoint(x: width * 0.76, y: height * 0.02),
                      control2: CGPoint(x: width * 0.96, y: height * 0.17))
        path.addCurve(to: CGPoint(x: width * 0.89, y: height * 0.57),
                      control1: CGPoint(x: width * 0.96, y: height * 0.43),
                      control2: CGPoint(x: width * 0.94, y: height * 0.5))
        path.addEllipse(in: CGRect(x: width * 0.39, y: height * 0.33 - width * 0.11,
                                  width: width * 0.22, height: width * 0.22))
        path.move(to: CGPoint(x: width * 0.65, y: height * 0.73))
        path.addLine(to: CGPoint(x: width, y: height * 0.73))
        path.move(to: CGPoint(x: width * 0.825, y: height * 0.56))
        path.addLine(to: CGPoint(x: width * 0.825, y: height * 0.9))
        return path
    }
}

private struct ChatView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            NavigationLink {
                TacticalMapView(model: model, settings: settings)
            } label: {
                Label("Select a map user", systemImage: "map")
            }
        }
        .navigationTitle("Chat")
    }
}

private struct PhysiologyView: View {
    @ObservedObject var monitor: PhysiologyMonitor
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        List {
            Section("Exertion") {
                if let exertion = monitor.exertionPercent {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(exertion)%")
                            .font(.system(size: 22, weight: .medium, design: .rounded))
                        Gauge(value: Double(exertion), in: 0...100) {
                            Text("Exertion")
                        } currentValueLabel: {
                            Text("\(exertion)%")
                        }
                        .gaugeStyle(.linearCapacity)
                    }
                } else {
                    Text("Unavailable")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Heart Rate") {
                HStack {
                    Text(monitor.heartRate.map { "\($0) BPM" } ?? "Unavailable")
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                    Spacer(minLength: 0)
                    if monitor.heartRate != nil {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Physiology")
        .task { await monitor.startViewing() }
        .onDisappear { monitor.stopViewing() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await monitor.startViewing() }
            }
        }
    }
}

private struct EnvironmentView: View {
    @ObservedObject var monitor: EnvironmentalMonitor
    @ObservedObject var settings: AppSettings

    var body: some View {
        List {
            Section("Altitude") {
                if let altitude = monitor.relativeAltitudeMeters {
                    Text(String(format: "%.1f m relative", altitude))
                        .font(.caption)
                } else {
                    Text("Unavailable")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Pressure") {
                if let pressure = monitor.pressureHpa {
                    Text(String(format: "%.1f hPa", pressure))
                        .font(.headline)
                } else {
                    Text("Unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Environment")
        .onAppear { monitor.startMonitoring() }
        .onDisappear {
            if !settings.environmentalAlertsEnabled {
                monitor.stopMonitoring()
            }
        }
    }
}

private struct TacticalMapView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var cameraHeading: Double = 0
    @State private var selectedMapPoint: MapPointSelection?
    @State private var visibleRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
        span: MKCoordinateSpan(latitudeDelta: 10, longitudeDelta: 10)
    )
    @State private var hasCentered = false
    @State private var pointDraft: MapPointDraft?
    @State private var showLayersMenu = false
    @State private var longPressStart: CGPoint?
    @State private var longPressTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            MapReader { proxy in
                Map(position: $cameraPosition, selection: $selectedMapPoint) {
                    if let location = model.lastLocation {
                        if let target = model.bloodhoundTarget {
                            MapPolyline(coordinates: [location.coordinate, target.coordinate])
                                .stroke(settings.teamColor.mapColor, lineWidth: 3)
                        }
                        Annotation("Self", coordinate: location.coordinate, anchor: .center) {
                            Image(systemName: "location.fill")
                                .font(.title3)
                                .foregroundStyle(settings.teamColor.mapColor)
                                .padding(4)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .tag(MapPointSelection.selfMarker)
                    }
                    ForEach(model.markers) { marker in
                        Annotation(marker.displayTitle, coordinate: marker.coordinate, anchor: .center) {
                            ZStack {
                                if marker.id == model.bloodhoundTargetID,
                                   let location = model.lastLocation,
                                   let reading = model.bloodhoundReading(from: location) {
                                    Image(systemName: "arrowtriangle.up.fill")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(settings.teamColor.mapColor)
                                        .shadow(color: .black, radius: 2)
                                        .offset(y: 22)
                                        .rotationEffect(.degrees(reading.bearingDegrees - cameraHeading))
                                        .allowsHitTesting(false)
                                        .accessibilityLabel("Direction to Bloodhound target")
                                }
                                MapPointSymbol(kind: marker.kind)
                            }
                        }
                            .tag(MapPointSelection.marker(marker.id))
                    }
                    ForEach(model.incomingEntities) { entity in
                        if !entity.isUser || settings.isMapUserVisible(team: entity.team, role: entity.role) {
                            Marker(entity.callSign.flatMap { $0.isEmpty ? nil : $0 } ?? entity.id,
                                   systemImage: entity.isUser ? "person.fill" : "mappin", coordinate: entity.coordinate)
                                .tint(incomingMapColor(entity))
                        }
                    }
                }
                .onMapCameraChange(frequency: .continuous) { context in
                    visibleRegion = context.region
                    cameraHeading = context.camera.heading
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            if longPressStart == nil {
                                longPressStart = value.startLocation
                                let startLocation = value.startLocation
                                longPressTask = Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 700_000_000)
                                    guard !Task.isCancelled,
                                          let coordinate = proxy.convert(startLocation, from: .local),
                                          CLLocationCoordinate2DIsValid(coordinate) else { return }
                                    model.addMarker(
                                        at: coordinate,
                                        kind: model.selectedMarkerKind,
                                        title: model.defaultPointTitle(),
                                        remark: ""
                                    )
                                    longPressTask = nil
                                }
                            } else if hypot(value.translation.width, value.translation.height) > 12 {
                                longPressTask?.cancel()
                                longPressTask = nil
                            }
                        }
                        .onEnded { _ in
                            longPressTask?.cancel()
                            longPressTask = nil
                            longPressStart = nil
                        }
                )
            }
            .onAppear(perform: centerOnce)
            .onChange(of: model.lastLocation?.timestamp) { _, _ in
                centerOnce()
            }
            .onChange(of: selectedMapPoint) { _, selection in
                guard let selection else { return }
                switch selection {
                case .selfMarker:
                    if let location = model.lastLocation {
                        pointDraft = MapPointDraft(coordinate: location.coordinate)
                    }
                case .marker(let id):
                    if let marker = model.markers.first(where: { $0.id == id }) {
                        pointDraft = MapPointDraft(marker: marker)
                    }
                }
                selectedMapPoint = nil
            }

            if settings.mapButtonsVisible {
                VStack(spacing: 0) {
                    Button {
                        zoom(by: 0.5)
                    } label: {
                        mapControl("plus", label: "Zoom in")
                    }
                    Spacer(minLength: 8)

                    Button {
                        centerOnLocation()
                    } label: {
                        mapControl("scope", label: "Snap to self")
                    }
                    .disabled(model.lastLocation == nil)
                    Spacer(minLength: 8)

                    Button {
                        zoom(by: 2)
                    } label: {
                        mapControl("minus", label: "Zoom out")
                    }
                }
                .padding(.leading, 5)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    mapControl("arrow.left", label: "Back to menu")
                }
            }
            .padding(.trailing, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            GeometryReader { geometry in
                Button {
                    showLayersMenu = true
                } label: {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 22))
                        .frame(width: 40, height: 36)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Layers Menu")
                .frame(maxWidth: .infinity, alignment: .top)
                .offset(y: -geometry.safeAreaInsets.top + 8)
            }
        }
        .buttonStyle(.plain)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bloodhoundPanel
        }
        .onAppear {
            updateBloodhoundHeading()
            #if DEBUG
            showLayersMenu = ProcessInfo.processInfo.arguments.contains("--preview-map-filters") ||
                ProcessInfo.processInfo.arguments.contains("--preview-empty-layers")
            #endif
        }
        .onDisappear { model.stopHeadingUpdates() }
        .onChange(of: model.bloodhoundTargetID) { _, _ in
            updateBloodhoundHeading()
        }
        .sheet(item: $pointDraft, onDismiss: updateBloodhoundHeading) { draft in
            NavigationStack {
                if let marker = draft.marker {
                    PointDetailView(model: model, marker: marker)
                } else {
                    SelfCoordinateView(coordinate: draft.coordinate)
                }
            }
        }
        .sheet(isPresented: $showLayersMenu, onDismiss: updateBloodhoundHeading) {
            NavigationStack {
                MapLayersMenuView(model: model, settings: settings)
            }
        }
    }

    @ViewBuilder
    private var bloodhoundPanel: some View {
        if model.bloodhoundTarget != nil {
            HStack(spacing: 10) {
                if let location = model.lastLocation,
                   let reading = model.bloodhoundCompassReading(from: location) {
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .rotationEffect(.degrees(reading.relativeBearingDegrees))
                        .foregroundStyle(settings.teamColor.mapColor)
                        .frame(width: 40, height: 40)
                        .accessibilityLabel("Direction to Bloodhound target")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reading.rangeMeters < 1000
                             ? "\(Int(reading.rangeMeters)) m"
                             : "\((reading.rangeMeters / 1000).formatted(.number.precision(.fractionLength(2)))) km")
                            .font(.headline)
                            .monospacedDigit()
                        Text(reading.isCompassRelative ? "To target" : "Compass unavailable")
                            .font(.caption2)
                            .foregroundStyle(reading.isCompassRelative ? Color.secondary : Color.orange)
                    }
                } else {
                    Text("Location unavailable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(.regularMaterial)
        }
    }

    private func updateBloodhoundHeading() {
        if model.bloodhoundTarget != nil {
            model.startHeadingUpdates()
        } else {
            model.stopHeadingUpdates()
        }
    }

    private func incomingMapColor(_ entity: IncomingMapEntity) -> Color {
        if entity.isUser, let team = entity.team,
           let color = TeamColor.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(team.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }) {
            return color.mapColor
        }
        return entity.kind == .hostile ? .red : entity.kind == .friendly ? .blue : .yellow
    }

    private func mapControl(_ systemName: String, label: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 36, height: 36)
            .background(.regularMaterial, in: Circle())
            .accessibilityLabel(label)
    }

    private func centerOnce() {
        guard !hasCentered else { return }
        centerOnLocation()
    }

    private func centerOnLocation() {
        guard let coordinate = model.lastLocation?.coordinate else { return }
        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        visibleRegion = region
        cameraPosition = .region(region)
        hasCentered = true
    }

    private func zoom(by factor: Double) {
        let span = MKCoordinateSpan(
            latitudeDelta: min(max(visibleRegion.span.latitudeDelta * factor, 0.0001), 180),
            longitudeDelta: min(max(visibleRegion.span.longitudeDelta * factor, 0.0001), 360)
        )
        let region = MKCoordinateRegion(center: visibleRegion.center, span: span)
        visibleRegion = region
        cameraPosition = .region(region)
    }
}

private struct MapLayersMenuView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Toggle("Map Buttons", isOn: $settings.mapButtonsVisible)
            if model.incomingUserTeams.isEmpty {
                Text("Team Colors (0)")
                    .font(.headline)
            } else {
                Section("Team Colors (\(model.incomingUserTeams.count))") {
                    ForEach(model.incomingUserTeams) { group in
                        Toggle(isOn: Binding(
                            get: { !settings.hiddenMapTeams.contains(group.id) },
                            set: { visible in
                                if visible { settings.hiddenMapTeams.remove(group.id) }
                                else { settings.hiddenMapTeams.insert(group.id) }
                            }
                        )) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(TeamColor.allCases.first { $0.rawValue.caseInsensitiveCompare(group.name) == .orderedSame }?.mapColor ?? .gray)
                                    .frame(width: 10, height: 10)
                                Text("\(group.name) (\(group.count))")
                            }
                        }
                    }
                }
            }
            if model.incomingUserRoles.isEmpty {
                Text("Default Roles (0)")
                    .font(.headline)
            } else {
                Section("Default Roles (\(model.incomingUserRoles.count))") {
                    ForEach(model.incomingUserRoles) { group in
                        Toggle("\(group.name) (\(group.count))", isOn: Binding(
                            get: { !settings.hiddenMapRoles.contains(group.id) },
                            set: { visible in
                                if visible { settings.hiddenMapRoles.remove(group.id) }
                                else { settings.hiddenMapRoles.insert(group.id) }
                            }
                        ))
                    }
                }
            }
            Button {
                dismiss()
            } label: {
                Label("Back", systemImage: "arrow.left")
            }
        }
        .navigationTitle("Layers Menu")
    }
}

private enum MapPointSelection: Hashable {
    case selfMarker
    case marker(UUID)
}

private struct MapPointDraft: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let marker: WatchMarker?

    init(marker: WatchMarker) {
        id = marker.id.uuidString
        coordinate = marker.coordinate
        self.marker = marker
    }

    init(coordinate: CLLocationCoordinate2D) {
        id = "self"
        self.coordinate = coordinate
        marker = nil
    }
}

private struct SelfCoordinateView: View {
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        List {
            Text(String(format: "Lat: %.5f", coordinate.latitude))
            Text(String(format: "Lon: %.5f", coordinate.longitude))
            Text(MapCoordinateFormatter.mgrs(coordinate) ?? "Unavailable")
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .navigationTitle("Self")
    }
}

private extension TeamColor {
    var mapColor: Color {
        switch self {
        case .white: return .white
        case .yellow: return .yellow
        case .orange: return .orange
        case .magenta: return Color(red: 1, green: 0, blue: 1)
        case .red: return .red
        case .maroon: return Color(red: 0.5, green: 0, blue: 0)
        case .purple: return .purple
        case .darkBlue: return Color(red: 0, green: 0.15, blue: 0.45)
        case .blue: return .blue
        case .cyan: return .cyan
        case .teal: return .teal
        case .green: return .green
        case .darkGreen: return Color(red: 0, green: 0.35, blue: 0.12)
        case .brown: return .brown
        }
    }
}

struct MapPointSymbol: View {
    let kind: MarkerKind

    var body: some View {
        Group {
            switch kind {
            case .friendly:
                Rectangle()
                    .fill(.cyan)
                    .overlay(Rectangle().stroke(.white, lineWidth: 1))
                    .frame(width: 16, height: 11)
            case .hostile:
                Rectangle()
                    .fill(.red)
                    .overlay(Rectangle().stroke(.white, lineWidth: 1))
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(45))
            case .neutral:
                Rectangle()
                    .fill(.green)
                    .overlay(Rectangle().stroke(.white, lineWidth: 1))
                    .frame(width: 14, height: 14)
            case .unknown:
                UnknownPointShape()
                    .fill(.yellow)
                    .overlay(UnknownPointShape().stroke(.black, lineWidth: 1))
                    .frame(width: 22, height: 22)
            }
        }
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
    }
}

private struct BloodhoundView: View {
    @ObservedObject var model: WatchSessionModel

    var body: some View {
        VStack(spacing: 8) {
            if let target = model.bloodhoundTarget {
                if let location = model.lastLocation,
                   let reading = model.bloodhoundCompassReading(from: location) {
                    Image(systemName: "location.north.fill")
                        .font(.largeTitle)
                        .rotationEffect(.degrees(reading.relativeBearingDegrees))
                        .animation(.linear(duration: 0.2), value: reading.relativeBearingDegrees)
                    Text(target.displayTitle)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                    Text("Range: \(Int(reading.rangeMeters)) m")
                        .font(.caption2)
                    if !reading.isCompassRelative {
                        Text("Compass unavailable")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text("Location unavailable")
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 54))
                    .rotationEffect(.degrees(model.headingDegrees.map { (360 - $0).truncatingRemainder(dividingBy: 360) } ?? 0))
                    .foregroundStyle(model.headingDegrees == nil ? .gray : .red)
                Text("Compass")
                Text(model.headingDegrees == nil ? "Compass unavailable" : "North")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(model.bloodhoundTarget == nil ? "Compass" : "Navigation")
        .onAppear { model.startHeadingUpdates() }
        .onDisappear { model.stopHeadingUpdates() }
    }
}

private struct ManualAlertView: View {
    @ObservedObject var model: WatchSessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let activeType = model.activeAlertType {
                LabeledContent("Active Alert", value: activeType.rawValue)
                Button(role: .destructive) {
                    model.cancelEmergencyAlert()
                    dismiss()
                } label: {
                    Label("Clear Manual Alert", systemImage: "xmark.circle.fill")
                }
            } else {
                ForEach(ManualAlertType.allCases) { type in
                    Button(type.rawValue) {
                        model.startEmergencyAlert(type: type)
                        dismiss()
                    }
                }
            }
            Button {
                dismiss()
            } label: {
                Label("Back", systemImage: "arrow.left")
            }
        }
        .navigationTitle("Manual Alert")
    }
}

private struct UnknownPointShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width * 0.5, y: 0))
        path.addCurve(to: CGPoint(x: rect.width * 0.75, y: rect.height * 0.25), control1: CGPoint(x: rect.width * 0.66, y: 0), control2: CGPoint(x: rect.width * 0.75, y: rect.height * 0.12))
        path.addCurve(to: CGPoint(x: rect.width, y: rect.height * 0.5), control1: CGPoint(x: rect.width * 0.88, y: rect.height * 0.25), control2: CGPoint(x: rect.width, y: rect.height * 0.34))
        path.addCurve(to: CGPoint(x: rect.width * 0.75, y: rect.height * 0.75), control1: CGPoint(x: rect.width, y: rect.height * 0.66), control2: CGPoint(x: rect.width * 0.88, y: rect.height * 0.75))
        path.addCurve(to: CGPoint(x: rect.width * 0.5, y: rect.height), control1: CGPoint(x: rect.width * 0.75, y: rect.height * 0.88), control2: CGPoint(x: rect.width * 0.66, y: rect.height))
        path.addCurve(to: CGPoint(x: rect.width * 0.25, y: rect.height * 0.75), control1: CGPoint(x: rect.width * 0.34, y: rect.height), control2: CGPoint(x: rect.width * 0.25, y: rect.height * 0.88))
        path.addCurve(to: CGPoint(x: 0, y: rect.height * 0.5), control1: CGPoint(x: rect.width * 0.12, y: rect.height * 0.75), control2: CGPoint(x: 0, y: rect.height * 0.66))
        path.addCurve(to: CGPoint(x: rect.width * 0.25, y: rect.height * 0.25), control1: CGPoint(x: 0, y: rect.height * 0.34), control2: CGPoint(x: rect.width * 0.12, y: rect.height * 0.25))
        path.addCurve(to: CGPoint(x: rect.width * 0.5, y: 0), control1: CGPoint(x: rect.width * 0.25, y: rect.height * 0.12), control2: CGPoint(x: rect.width * 0.34, y: 0))
        path.closeSubpath()
        return path
    }
}

struct PointListView: View {
    @ObservedObject var model: WatchSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClearAll = false
    @State private var expandedMarkerID: UUID?
    @State private var markerToDelete: WatchMarker?
    @State private var confirmDelete = false

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 210
            VStack(spacing: compact ? 4 : 8) {
            ScrollView {
                VStack(spacing: 8) {
                    if model.markers.isEmpty {
                        Text("No dropped markers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 20)
                    }
                    ForEach(model.markers) { marker in
                        HStack(spacing: 5) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    expandedMarkerID = expandedMarkerID == marker.id ? nil : marker.id
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    MapPointSymbol(kind: marker.kind)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(marker.displayTitle)
                                            .font(.system(size: compact ? 12 : 14, weight: .semibold))
                                            .lineLimit(expandedMarkerID == marker.id ? 1 : 2)
                                            .minimumScaleFactor(0.8)
                                            .multilineTextAlignment(.leading)
                                        Text(marker.kind.rawValue)
                                            .font(.system(size: compact ? 11 : 12))
                                            .lineLimit(1)
                                        Text(marker.createdAt, format: .dateTime.hour().minute().second())
                                            .font(.system(size: compact ? 11 : 12))
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(compact ? 6 : 10)
                                .frame(maxWidth: .infinity, minHeight: compact ? 64 : 80, alignment: .leading)
                                .background(Color(white: 0.26), in: RoundedRectangle(cornerRadius: 8))
                            }
                            .accessibilityLabel("\(marker.displayTitle), \(marker.kind.rawValue). Marker actions")
                            if expandedMarkerID == marker.id {
                                NavigationLink {
                                    PointDetailView(model: model, marker: marker)
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .rotationEffect(.degrees(90))
                                        .font(.system(size: 23, weight: .bold))
                                        .frame(width: 34, height: compact ? 64 : 80)
                                        .background(Color(white: 0.19), in: Capsule())
                                }
                                .accessibilityLabel("Edit \(marker.displayTitle)")
                                Button {
                                    markerToDelete = marker
                                    confirmDelete = true
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 21))
                                        .foregroundStyle(.black)
                                        .frame(width: 34, height: compact ? 64 : 80)
                                        .background(Color(red: 0.94, green: 0.39, blue: 0.35), in: Capsule())
                                }
                                .accessibilityLabel("Delete \(marker.displayTitle)")
                            }
                        }
                    }
                }
            }
            Button { confirmClearAll = true } label: {
                Text("Clear All Markers")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? 30 : 42)
                    .background(model.markers.isEmpty ? Color(white: 0.26) : .red, in: Capsule())
            }
            .padding(.horizontal, 10)
            .disabled(model.markers.isEmpty)
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 72, height: compact ? 30 : 40)
                    .background(Color(white: 0.5), in: Capsule())
            }
            .accessibilityLabel("Back")
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        }
        .background(.black)
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .confirmationDialog("Clear all dropped markers?", isPresented: $confirmClearAll) {
            Button("Clear All Markers", role: .destructive) {
                model.clearAllPoints()
                expandedMarkerID = nil
            }
        }
        .confirmationDialog("Delete marker?", isPresented: $confirmDelete) {
            Button("Delete Marker", role: .destructive) {
                if let markerToDelete {
                    model.deleteMarker(id: markerToDelete.id)
                    self.markerToDelete = nil
                    expandedMarkerID = nil
                }
            }
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-marker-actions") {
                expandedMarkerID = model.markers.first?.id
            }
            #endif
        }
    }
}

private struct PointDetailView: View {
    @ObservedObject var model: WatchSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var marker: WatchMarker
    @State private var confirmDelete = false

    init(model: WatchSessionModel, marker: WatchMarker) {
        self.model = model
        _marker = State(initialValue: marker)
    }

    var body: some View {
        List {
            Section {
                Text(marker.displayTitle)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                HStack {
                    Text(marker.kind.rawValue)
                    Spacer(minLength: 4)
                    Text(MapCoordinateFormatter.droppedTime(marker.createdAt))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let remark = marker.remark?.trimmingCharacters(in: .whitespacesAndNewlines), !remark.isEmpty {
                Section {
                    Text("Remark: \(remark)")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.bloodhoundTargetID == marker.id {
                Section {
                    Label("Bloodhounding", systemImage: "location.north.fill")
                }
            }
            Section {
                HStack(alignment: .top, spacing: 6) {
                    VStack(spacing: 4) {
                        Text("From You")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let location = model.lastLocation {
                            let reading = model.mapPointReading(to: marker.coordinate, from: location)
                            Image(systemName: "location.north.fill")
                                .font(.title3)
                                .rotationEffect(.degrees(reading.relativeBearingDegrees))
                            Text("\(Int(reading.bearingDegrees.rounded()))° \(MapCoordinateFormatter.cardinalDirection(reading.bearingDegrees))")
                                .font(.caption2.monospacedDigit())
                                .multilineTextAlignment(.center)
                        } else {
                            Image(systemName: "location.slash")
                                .font(.title3)
                            Text("Unavailable")
                                .font(.caption2)
                        }
                    }
                    .frame(width: 58)

                    Divider()

                    VStack(alignment: .leading, spacing: 3) {
                        if let location = model.lastLocation {
                            Text(String(format: "%.2f km", location.distance(from: CLLocation(latitude: marker.latitude, longitude: marker.longitude)) / 1000))
                                .font(.caption.bold())
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        } else {
                            Text("Distance unavailable")
                                .font(.caption.bold())
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        Text(String(format: "%.5f", marker.latitude))
                        Text(String(format: "%.5f", marker.longitude))
                        Text(MapCoordinateFormatter.mgrs(marker.coordinate) ?? "Unavailable")
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                    }
                    .font(.caption2.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section {
                Button(model.bloodhoundTargetID == marker.id ? "Stop Bloodhound" : "Bloodhound to Marker") {
                    model.toggleBloodhound(id: marker.id)
                }

                NavigationLink("Change Title") {
                    PointTextEditorView(title: "Change Title", value: marker.title ?? "") { value in
                        update(title: value)
                    }
                }

                NavigationLink(marker.remark?.isEmpty == false ? "Change Remark" : "Add Remark") {
                    PointTextEditorView(
                        title: marker.remark?.isEmpty == false ? "Change Remark" : "Add Remark",
                        value: marker.remark ?? ""
                    ) { value in
                        update(remark: value)
                    }
                }

                NavigationLink("Change Marker") {
                    PointMarkerTypeView(selection: marker.kind) { selectedKind in
                        update(kind: selectedKind)
                    }
                }

                Button("Move to Current Location") {
                    guard let location = model.lastLocation else { return }
                    model.moveMarker(id: marker.id, to: location.coordinate)
                    marker.latitude = location.coordinate.latitude
                    marker.longitude = location.coordinate.longitude
                }
                .disabled(model.lastLocation == nil)

                Button("Delete Marker", role: .destructive) {
                    confirmDelete = true
                }

                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "arrow.left")
                }
            }
        }
        .navigationTitle("Point Details")
        .onAppear {
            model.requestLocation()
            model.startHeadingUpdates()
        }
        .onDisappear { model.stopHeadingUpdates() }
        .confirmationDialog("Delete point?", isPresented: $confirmDelete) {
            Button("Delete Marker", role: .destructive) {
                model.deleteMarker(id: marker.id)
                dismiss()
            }
        }
    }

    private func update(kind: MarkerKind? = nil, title: String? = nil, remark: String? = nil) {
        if let kind { marker.kind = kind }
        if let title { marker.title = title }
        if let remark { marker.remark = remark }
        model.updateMarker(id: marker.id, kind: marker.kind, title: marker.title ?? "", remark: marker.remark ?? "")
    }
}

private struct PointTextEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var value: String
    let title: String
    let onSave: (String) -> Void

    init(title: String, value: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.onSave = onSave
        _value = State(initialValue: value)
    }

    var body: some View {
        List {
            TextField(title, text: $value)
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave(value)
                    dismiss()
                }
            }
        }
    }
}

private struct PointMarkerTypeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: MarkerKind
    let onSelect: (MarkerKind) -> Void

    init(selection: MarkerKind, onSelect: @escaping (MarkerKind) -> Void) {
        self.onSelect = onSelect
        _selection = State(initialValue: selection)
    }

    private let choices: [MarkerKind] = [.unknown, .hostile, .friendly, .neutral]

    var body: some View {
        List(choices) { kind in
            Button {
                selection = kind
                onSelect(kind)
                dismiss()
            } label: {
                HStack {
                    Text(kind.rawValue)
                    Spacer()
                    if selection == kind {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        .navigationTitle("Change Marker")
    }
}

private extension CLLocationCoordinate2D {
    var formatted: String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }
}
