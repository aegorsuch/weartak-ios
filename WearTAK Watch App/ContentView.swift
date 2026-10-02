import CoreLocation
import MapKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var physiology: PhysiologyMonitor
    @ObservedObject var environment: EnvironmentalMonitor
    @ObservedObject var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var showClearPointsConfirmation = false
    @State private var toastMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if settings.chatEnabled {
                    NavigationLink { ChatView() } label: {
                        Label("Chat", systemImage: "message")
                    }
                }
                Button(role: .destructive) {
                    showClearPointsConfirmation = true
                } label: {
                    Label("Clear 2525D Points", systemImage: "trash")
                }
                Button {
                    if model.dropMarker() {
                        showToast("2525D point dropped")
                    } else {
                        model.requestLocation()
                        showToast("Location unavailable")
                    }
                } label: {
                    Label("Drop 2525D Point", systemImage: "mappin.and.ellipse")
                }
                NavigationLink {
                    EnvironmentView(monitor: environment, settings: settings)
                } label: {
                    Label("Environment", systemImage: "barometer")
                }
                if let activeAlertType = model.activeAlertType {
                    Button(role: .destructive) {
                        model.cancelEmergencyAlert()
                    } label: {
                        Label("Clear Manual Alert (\(activeAlertType.rawValue) Active)", systemImage: "xmark.circle.fill")
                    }
                } else {
                    NavigationLink {
                        ManualAlertView(model: model)
                    } label: {
                        Label("Manual Alert", systemImage: "exclamationmark.triangle.fill")
                    }
                }
                NavigationLink {
                    TacticalMapView(model: model, settings: settings)
                } label: {
                    Label("Map", systemImage: "map")
                }
                NavigationLink {
                    PhysiologyView(monitor: physiology)
                } label: {
                    Label("Physiology", systemImage: "heart.text.square")
                }
                NavigationLink {
                    SettingsView(model: model, settings: settings)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .navigationTitle("WearTAK")
            .confirmationDialog("Clear app points?", isPresented: $showClearPointsConfirmation) {
                Button("Clear 2525D Points", role: .destructive) {
                    model.clearAllPoints()
                    showToast("Old points cleared")
                }
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
        .task {
            model.connect()
            model.requestLocation()
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
                physiology.stopViewing()
                physiology.stopMonitoring()
                environment.stopMonitoring()
            } else if phase == .active {
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

private struct ChatView: View {
    var body: some View {
        List {
            Text("Select a map user")
                .foregroundStyle(.secondary)
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
    @State private var longPressStart: CGPoint?
    @State private var longPressTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            MapReader { proxy in
                Map(position: $cameraPosition, selection: $selectedMapPoint) {
                    if let location = model.lastLocation {
                        Annotation("Self", coordinate: location.coordinate, anchor: .center) {
                            ZStack {
                                Image(systemName: "location.fill")
                                    .font(.title3)
                                    .foregroundStyle(settings.teamColor.mapColor)
                                    .padding(4)
                                    .background(.ultraThinMaterial, in: Circle())
                                if let reading = model.bloodhoundReading(from: location) {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 24, weight: .heavy))
                                        .foregroundStyle(settings.teamColor.mapColor)
                                        .shadow(color: .black, radius: 2)
                                        .offset(y: -32)
                                        .rotationEffect(.degrees(reading.bearingDegrees - cameraHeading))
                                        .allowsHitTesting(false)
                                        .accessibilityLabel("Direction to Bloodhound target")
                                }
                            }
                        }
                        .tag(MapPointSelection.selfMarker)
                    }
                    ForEach(model.markers) { marker in
                        Annotation(marker.displayTitle, coordinate: marker.coordinate, anchor: .center) {
                            MapPointSymbol(kind: marker.kind)
                        }
                            .tag(MapPointSelection.marker(marker.id))
                    }
                    ForEach(model.incomingEntities) { entity in
                        Marker(entity.id, systemImage: "person.fill", coordinate: entity.coordinate)
                            .tint(entity.kind == .hostile ? .red : entity.kind == .friendly ? .blue : .yellow)
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
                                        kind: .unknown,
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
        .buttonStyle(.plain)
        .navigationBarBackButtonHidden(true)
        .navigationTitle("Map")
        .sheet(item: $pointDraft) { draft in
            NavigationStack {
                if let marker = draft.marker {
                    PointDetailView(model: model, marker: marker)
                } else {
                    SelfCoordinateView(coordinate: draft.coordinate)
                }
            }
        }
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

private struct MapPointSymbol: View {
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
                Image(systemName: "plus")
                    .font(.system(size: 21, weight: .black))
                    .foregroundStyle(.yellow)
                    .shadow(color: .black, radius: 1)
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
                Text("No Bloodhound target")
                Text("Tap a map point to start")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Navigation")
        .onAppear { model.startHeadingUpdates() }
        .onDisappear { model.stopHeadingUpdates() }
    }
}

private struct ManualAlertView: View {
    @ObservedObject var model: WatchSessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(ManualAlertType.allCases) { type in
                Button(type.rawValue) {
                    model.startEmergencyAlert(type: type)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {
                dismiss()
            }
        }
        .navigationTitle("Manual Alert")
    }
}

private struct PointListView: View {
    @ObservedObject var model: WatchSessionModel
    @State private var confirmClearAll = false

    var body: some View {
        List {
            Section("Dropped points") {
                if model.markers.isEmpty {
                    Text("No points")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.markers) { marker in
                    NavigationLink {
                        PointDetailView(model: model, marker: marker)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(marker.displayTitle)
                            Text(marker.kind.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !model.markers.isEmpty {
                    Button("Clear 2525D Points", role: .destructive) {
                        confirmClearAll = true
                    }
                }
            }
            if !model.incomingEntities.isEmpty {
                Section("Incoming") {
                    ForEach(model.incomingEntities) { entity in
                        VStack(alignment: .leading) {
                            Text(entity.id)
                            Text(entity.coordinate.formatted)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Points")
        .confirmationDialog("Clear app points?", isPresented: $confirmClearAll) {
            Button("Clear 2525D Points", role: .destructive) {
                model.clearAllPoints()
            }
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
