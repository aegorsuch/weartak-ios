import CoreLocation
import MapKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: WatchSessionModel
    @ObservedObject var physiology: PhysiologyMonitor
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section {
                    connectionRow
                    Button {
                        model.requestLocation()
                    } label: {
                        Label("Send position", systemImage: "location.fill")
                    }
                }

                Section("Actions") {
                    NavigationLink {
                        PhysiologyView(monitor: physiology)
                    } label: {
                        Label("Physiology", systemImage: "heart.text.square")
                    }

                    NavigationLink {
                        TacticalMapView(model: model)
                    } label: {
                        Label("Map", systemImage: "map")
                    }

                    NavigationLink {
                        PointEditorView(model: model, coordinate: model.lastLocation?.coordinate)
                    } label: {
                        Label("Drop marker", systemImage: "mappin.and.ellipse")
                    }
                    .disabled(model.lastLocation == nil)

                    if let activeAlertType = model.activeAlertType {
                        Button(role: .destructive) {
                            model.cancelEmergencyAlert()
                        } label: {
                            Label {
                                Text("Manual Alert (\(activeAlertType.rawValue) Active)")
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: "xmark.circle.fill")
                            }
                        }
                    } else {
                        NavigationLink {
                            ManualAlertView(model: model)
                        } label: {
                            Label("Manual Alert", systemImage: "exclamationmark.triangle.fill")
                        }
                    }
                }
            }
            .navigationTitle("WearTAK")
        }
        .task {
            model.connect()
            model.requestLocation()
        }
        .onChange(of: physiology.activeAutomaticAlert) { _, category in
            model.updateAutomaticAlert(category)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                physiology.stopMonitoring()
            }
        }
    }

    private var connectionRow: some View {
        HStack {
            Circle()
                .fill(model.connectionState == .connected ? .green : .yellow)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading) {
                Text(model.connectionState.rawValue)
                    .font(.headline)
                if let activeAlertType = model.activeAlertType {
                    Text("ALERTING: \(activeAlertType.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let category = model.activeAutomaticAlert {
                    Text("AUTO ALERT: \(category.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.automaticAlertDeliveryFailed {
                        Text("Not delivered")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                } else if model.automaticAlertDeliveryFailed {
                    Text("Remote alert clear failed")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let location = model.lastLocation {
                    Text(location.coordinate.formatted)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Location unavailable")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct PhysiologyView: View {
    @ObservedObject var monitor: PhysiologyMonitor

    var body: some View {
        List {
            Section("Heart rate") {
                VStack(alignment: .leading, spacing: 4) {
                    if let heartRate = monitor.heartRate {
                        Text("\(heartRate) BPM")
                            .font(.title2)
                    }
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
            Section("Automatic alerts") {
                Toggle("Monitor", isOn: Binding(
                    get: { monitor.automaticEnabled },
                    set: { enabled in
                        if enabled {
                            Task { await monitor.startMonitoring() }
                        } else {
                            monitor.stopMonitoring()
                        }
                    }
                ))
                .disabled(monitor.isStarting)
                if let category = monitor.activeAutomaticAlert {
                    Text("ALERT: \(category.rawValue)")
                        .foregroundStyle(.red)
                } else if let category = monitor.warningCategory {
                    Text("Warning: \(category.rawValue)")
                        .foregroundStyle(.orange)
                }
            }
            Button {
                Task { await monitor.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .navigationTitle("Physiology")
        .task { await monitor.refresh() }
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

private struct ManualAlertView: View {
    @ObservedObject var model: WatchSessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(ManualAlertType.allCases) { type in
            Button(type.rawValue) {
                model.startEmergencyAlert(type: type)
                dismiss()
            }
        }
        .navigationTitle("Alert Type")
    }
}

private struct PointListView: View {
    @ObservedObject var model: WatchSessionModel

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
                Section("Location") {
                    Text(coordinate.formatted)
                        .font(.caption2)
                }
            }
            Section("Details") {
                Picker("Type", selection: $kind) {
                    ForEach(MarkerKind.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                TextField("Title", text: $title)
                TextField("Remark", text: $remark)
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
