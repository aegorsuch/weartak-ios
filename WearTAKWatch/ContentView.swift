import CoreLocation
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: WatchSessionModel

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
                        MarkerView(model: model)
                    } label: {
                        Label("Drop marker", systemImage: "mappin.and.ellipse")
                    }

                    Button(role: .destructive) {
                        model.toggleEmergencyAlert()
                    } label: {
                        Label(
                            model.isAlerting ? "Cancel alert" : "SOS alert",
                            systemImage: model.isAlerting ? "xmark" : "exclamationmark.triangle.fill"
                        )
                    }
                }
            }
            .navigationTitle("WearTAK")
        }
        .task {
            model.connect()
            model.requestLocation()
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

private struct MarkerView: View {
    @ObservedObject var model: WatchSessionModel

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
                Button("Publish marker") {
                    model.dropMarker()
                }
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
