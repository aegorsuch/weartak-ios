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
                    TacticalMapView(model: model)
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
            Section("Heart Rate") {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if let heartRate = monitor.heartRate {
                        Text("\(heartRate)")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                        Text("BPM")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.red)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(monitor.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let readingDate = monitor.readingDate {
                        Text(readingDate, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Exertion") {
                if let exertion = monitor.exertionPercent {
                    Gauge(value: Double(exertion), in: 0...100) {
                        Text("Exertion")
                    } currentValueLabel: {
                        Text("\(exertion)%")
                    }
                    .gaugeStyle(.linearCapacity)
                } else {
                    Text("Unavailable")
                        .foregroundStyle(.secondary)
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
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasCentered = false
    @State private var isPlacingPoint = false
    @State private var pointDraft: MapPointDraft?

    var body: some View {
        VStack(spacing: 4) {
            MapReader { proxy in
                Map(position: $cameraPosition) {
                    if let coordinate = model.lastLocation?.coordinate {
                        Marker("You", systemImage: "location.fill", coordinate: coordinate)
                            .tint(.blue)
                    }
                    ForEach(model.markers) { marker in
                        Marker(marker.displayTitle, coordinate: marker.coordinate)
                    }
                    ForEach(model.incomingEntities) { entity in
                        Marker(entity.id, systemImage: "person.fill", coordinate: entity.coordinate)
                            .tint(entity.kind == .hostile ? .red : entity.kind == .friendly ? .blue : .yellow)
                    }
                }
                .onTapGesture { location in
                    guard isPlacingPoint,
                          let coordinate = proxy.convert(location, from: .local),
                          CLLocationCoordinate2DIsValid(coordinate) else { return }
                    isPlacingPoint = false
                    pointDraft = MapPointDraft(coordinate: coordinate)
                }
            }
            .onAppear(perform: centerOnce)
            .onChange(of: model.lastLocation?.timestamp) { _, _ in
                centerOnce()
            }

            HStack(spacing: 4) {
                Button {
                    centerOnLocation()
                } label: {
                    Image(systemName: "location.north.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(model.lastLocation == nil)
                .accessibilityLabel("Recenter map")

                NavigationLink {
                    PointListView(model: model)
                } label: {
                    Image(systemName: "list.bullet")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityLabel("Points")

                NavigationLink {
                    BloodhoundView(model: model)
                } label: {
                    Image(systemName: "location.viewfinder")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityLabel("Navigation")

                Button {
                    isPlacingPoint.toggle()
                } label: {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(isPlacingPoint ? .orange : .primary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .accessibilityLabel("Place point on map")
                .help("Tap the map to place a point")

                NavigationLink {
                    PointEditorView(model: model, coordinate: model.lastLocation?.coordinate)
                } label: {
                    Image(systemName: "location.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(model.lastLocation == nil)
                .accessibilityLabel("Drop point at GPS location")
            }
            .buttonStyle(.plain)
            .frame(height: 44)
        }
        .navigationTitle("Map")
        .sheet(item: $pointDraft) { draft in
            NavigationStack {
                PointEditorView(model: model, coordinate: draft.coordinate)
            }
        }
    }

    private func centerOnce() {
        guard !hasCentered else { return }
        centerOnLocation()
    }

    private func centerOnLocation() {
        guard let coordinate = model.lastLocation?.coordinate else { return }
        cameraPosition = .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))
        hasCentered = true
    }
}

private struct MapPointDraft: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
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
                        PointEditorView(model: model, marker: marker)
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

private struct PointEditorView: View {
    @ObservedObject var model: WatchSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind: MarkerKind
    @State private var title: String
    @State private var remark: String
    @State private var confirmDelete = false

    private let markerID: UUID?
    private let coordinate: CLLocationCoordinate2D?

    init(model: WatchSessionModel, marker: WatchMarker? = nil, coordinate: CLLocationCoordinate2D? = nil) {
        self.model = model
        markerID = marker?.id
        self.coordinate = marker?.coordinate ?? coordinate
        _kind = State(initialValue: marker?.kind ?? model.selectedMarkerKind)
        _title = State(initialValue: marker?.title ?? "")
        _remark = State(initialValue: marker?.remark ?? "")
    }

    var body: some View {
        List {
            if let coordinate {
                Section("Lat/Lon") {
                    Text(coordinate.formatted)
                        .font(.caption2)
                }
            }
            Section("Details") {
                Picker("Set Type", selection: $kind) {
                    ForEach(MarkerKind.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                TextField("Set Title", text: $title)
                TextField("Set Remark", text: $remark)
            }

            if let markerID {
                Section {
                    Button(model.bloodhoundTargetID == markerID ? "Stop Bloodhound" : "Bloodhound") {
                        model.toggleBloodhound(id: markerID)
                    }
                }
            }

            Section {
                Button(markerID == nil ? "Drop point" : "Save point") {
                    if let markerID {
                        model.updateMarker(id: markerID, kind: kind, title: title, remark: remark)
                        dismiss()
                    } else if let coordinate,
                              model.addMarker(at: coordinate, kind: kind, title: title, remark: remark) {
                        dismiss()
                    }
                }
                .disabled(coordinate == nil)
                if markerID != nil {
                    Button("Delete point", role: .destructive) {
                        confirmDelete = true
                    }
                }
            }
        }
        .navigationTitle(markerID == nil ? "Drop Point" : "Edit Point")
        .confirmationDialog("Delete point?", isPresented: $confirmDelete) {
            Button("Delete point", role: .destructive) {
                if let markerID {
                    model.deleteMarker(id: markerID)
                    dismiss()
                }
            }
        }
    }
}

private extension CLLocationCoordinate2D {
    var formatted: String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }
}
