import SwiftUI

struct BloodhoundPickerRow: View {
    let title: String
    let subtitle: String
    let glyph: String
    let active: Bool
    var available = true
    let showDetail: () -> Void
    let showMap: () -> Void
    let navigate: () -> Void

    private let amber = Color(red: 1, green: 0.7, blue: 0)
    private let green = Color(red: 0.12, green: 0.37, blue: 0.16)
    private let red = Color(red: 0.70, green: 0.15, blue: 0.12)

    var body: some View {
        HStack(spacing: 2) {
            Button(action: showDetail) {
                HStack(spacing: 5) {
                    Image(systemName: glyph).font(.caption2).frame(width: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.caption).lineLimit(2)
                        Text(subtitle).font(.caption2)
                            .foregroundStyle(active ? Color(red: 1, green: 0.84, blue: 0.5) : Color(white: 0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityHint(Text("Show details"))
            Button(action: showMap) {
                Image("ATAKCrosshair").resizable().scaledToFit()
                    .frame(width: 23, height: 23)
                    .frame(width: 34, height: 34)
                    .background(Color(white: 0.22), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!available)
            .accessibilityLabel(Text("Show \(title) on map"))
            Button(action: navigate) {
                Group {
                    if active {
                        Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold))
                    } else {
                        Image("ATAKBloodhound").resizable().scaledToFit().padding(5)
                    }
                }
                .frame(width: 34, height: 34)
                .background(active ? red : green, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .disabled(!active && !available)
            .accessibilityLabel(active ? Text(String(localized: "Stop Bloodhound", table: "WatchMain")) : Text("Bloodhound to \(title)"))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .padding(.vertical, 4)
        .background(active ? Color(red: 0.23, green: 0.16, blue: 0) : Color(white: 0.13), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(active ? amber : .clear, lineWidth: 1.5))
        .accessibilityElement(children: .contain)
    }
}

struct BloodhoundRouteStartView: View {
    @ObservedObject var model: WatchSessionModel
    let routeID: String
    @Environment(\.dismiss) private var dismiss

    private var route: GarminRoute? { model.watchRoutes.routes.first { $0.id == routeID } }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { _ in
            chooser
        }
        .onAppear { model.requestLocation() }
    }

    private var chooser: some View {
        ScrollView {
            VStack(spacing: 10) {
                if let route {
                    Text(route.name).font(.headline).multilineTextAlignment(.center)
                    Text("Start Bloodhound").font(.caption).foregroundStyle(.secondary)
                    Button {
                        guard model.routeLocation != nil else {
                            model.requestLocation()
                            return
                        }
                        model.startRouteFollowing(route, start: .nearest)
                        dismiss()
                    } label: {
                        HStack {
                            Image("ATAKBloodhound").resizable().scaledToFit().frame(width: 24, height: 24)
                            Text("Start nearest")
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.12, green: 0.37, blue: 0.16))
                    .disabled(model.routeLocation == nil)
                    if model.routeLocation == nil {
                        Text("Start nearest requires a current location. Enable location and try again.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Button("Start from beginning") {
                        model.startRouteFollowing(route, start: .beginning)
                        dismiss()
                    }
                    .frame(minHeight: 44)
                } else {
                    Text("This route is no longer on this watch.")
                }
                Button(String(localized: "Cancel", table: "WatchMain"), role: .cancel) { dismiss() }.frame(minHeight: 44)
            }
            .padding(.horizontal, 4)
        }
    }
}
