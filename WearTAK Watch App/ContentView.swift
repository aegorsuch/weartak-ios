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
                        MarkerView(model: model)
                    } label: {
                        Label("Drop marker", systemImage: "mappin.and.ellipse")
                    }

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

    var body: some View {
        VStack(spacing: 4) {
            Map(position: $cameraPosition) {
                if let coordinate = model.lastLocation?.coordinate {
                    Marker("You", systemImage: "location.fill", coordinate: coordinate)
                        .tint(.blue)
                }
                ForEach(model.markers) { marker in
                    Marker(marker.kind.rawValue, coordinate: marker.coordinate)
                }
            }
            .onAppear(perform: centerOnce)
            .onChange(of: model.lastLocation?.timestamp) { _, _ in
                centerOnce()
            }

            HStack {
                Button {
                    centerOnLocation()
                } label: {
                    Image(systemName: "location.north.fill")
                }
                .disabled(model.lastLocation == nil)
                .accessibilityLabel("Recenter map")

                NavigationLink {
                    MarkerView(model: model)
                } label: {
                    Label("Drop point", systemImage: "mappin.and.ellipse")
                }
            }
        }
        .navigationTitle("Map")
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

private struct MarkerView: View {
    @ObservedObject var model: WatchSessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Type") {
                ForEach(MarkerKind.allCases) { kind in
                    Button {
                        model.selectedMarkerKind = kind
                    } label: {
                        HStack {
                            Text(kind.rawValue)
                            Spacer()
                            if model.selectedMarkerKind == kind {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }

            Section {
                Button("Drop point") {
                    if model.dropMarker() {
                        dismiss()
                    }
                }
                .disabled(model.lastLocation == nil)
            }
        }
        .navigationTitle("Marker")
    }
}

private extension CLLocationCoordinate2D {
    var formatted: String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }
}
