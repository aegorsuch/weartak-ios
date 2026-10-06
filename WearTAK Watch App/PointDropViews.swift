import CoreLocation
import SwiftUI

struct PointTypePickerView: View {
    @ObservedObject var model: WatchSessionModel
    let onDrop: (MarkerKind) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var showTools = false
    @State private var dropDraft: PointDropDraft?

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height) - 10
            ZStack {
                sector(.hostile, angle: -90, diameter: diameter)
                sector(.neutral, angle: -180, diameter: diameter)
                sector(.friendly, angle: 0, diameter: diameter)
                sector(.unknown, angle: 90, diameter: diameter)
                holdHint(diameter: diameter)
                Image(systemName: "xmark")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.black)
                    .frame(width: diameter * 0.29, height: diameter * 0.29)
                    .background(Color(white: 0.8), in: Circle())
                    .contentShape(Circle())
                    .gesture(LongPressGesture(minimumDuration: 0.6).exclusively(before: TapGesture()).onEnded { gesture in
                        switch gesture {
                        case .first: showTools = true
                        case .second: dismiss()
                        }
                    })
                    .accessibilityLabel(String(localized: "Cancel point drop", table: "PointDrop"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { dismiss() }
                    .accessibilityAction(named: Text(String(localized: "Marker options", table: "PointDrop"))) { showTools = true }
            }
            .frame(width: diameter, height: diameter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.black)
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .navigationDestination(isPresented: $showTools) { PointToolsView(model: model) }
        .sheet(item: $dropDraft) { draft in
            NavigationStack {
                PointDropConfirmationView(model: model, draft: draft) {
                    onDrop(draft.kind)
                    dismiss()
                }
            }
        }
        .onAppear {
            #if DEBUG
            showTools = ProcessInfo.processInfo.arguments.contains("--preview-marker-tools")
            if ProcessInfo.processInfo.arguments.contains("--preview-point-confirmation") {
                dropDraft = PointDropDraft(
                    coordinate: CLLocationCoordinate2D(latitude: 41.88, longitude: -87.64),
                    kind: .unknown
                )
            }
            #endif
        }
    }

    @ViewBuilder
    private func holdHint(diameter: CGFloat) -> some View {
        let hint = String(localized: "Hold for more", table: "PointDrop", comment: "Hint above the cancel button; long-press for marker options. Drawn along a curve, one character at a time, in left-to-right languages")
        // Per-character placement breaks RTL ordering and Arabic letter joining, so RTL text is drawn as one run.
        if layoutDirection == .rightToLeft || Self.containsRightToLeftScript(hint) {
            Text(hint)
                .font(.system(size: 11))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: diameter * 0.34)
                .position(x: diameter * 0.5, y: diameter * (0.5 - 0.19))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            let caption = Array(hint)
            ForEach(caption.indices, id: \.self) { index in
                let angle = -160.0 + 140.0 * Double(index) / Double(max(caption.count - 1, 1))
                Text(String(caption[index]))
                    .font(.system(size: 11))
                    .rotationEffect(.degrees(angle + 90))
                    .position(x: diameter * (0.5 + 0.20 * cos(angle * .pi / 180)),
                              y: diameter * (0.5 + 0.20 * sin(angle * .pi / 180)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    private static func containsRightToLeftScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
                return true
            default:
                return false
            }
        }
    }

    private func sector(_ kind: MarkerKind, angle: Double, diameter: CGFloat) -> some View {
        let shape = PointTypeSector(start: .degrees(angle - 43), end: .degrees(angle + 43))
        return Button {
            guard dropDraft == nil else { return }
            dropDraft = PointDropDraft(coordinate: model.usableMarkerCoordinate, kind: kind)
        } label: {
            shape.fill(Color(white: 0.26))
                .overlay {
                    VStack(spacing: 2) {
                        MapPointSymbol(kind: kind)
                            .frame(width: 24, height: 24)
                        Text(kind.pointDropLabel).font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .frame(width: diameter * 0.37, height: 40)
                    .position(x: diameter * (0.5 + 0.34 * cos(angle * .pi / 180)),
                              y: diameter * (0.5 + 0.38 * sin(angle * .pi / 180)))
                }
                .contentShape(shape)
        }
        .accessibilityLabel(String(localized: "Drop \(kind.pointDropLabel) point", table: "PointDrop", comment: "Accessibility label; %@ is the localized marker type (Friendly, Neutral, Unknown, Hostile)"))
    }
}

private extension MarkerKind {
    /// Localized display name; `rawValue` stays unchanged for persistence and network use.
    var pointDropLabel: String {
        switch self {
        case .friendly: return String(localized: "Friendly", table: "PointDrop", comment: "Marker type label")
        case .neutral: return String(localized: "Neutral", table: "PointDrop", comment: "Marker type label")
        case .unknown: return String(localized: "Unknown", table: "PointDrop", comment: "Marker type label")
        case .hostile: return String(localized: "Hostile", table: "PointDrop", comment: "Marker type label")
        }
    }
}

struct PointDropDraft: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D?
    let kind: MarkerKind
}

struct PointDropConfirmationView: View {
    @ObservedObject var model: WatchSessionModel
    let draft: PointDropDraft
    let onDrop: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var remark = ""
    @State private var locationUnavailable = false
    @State private var isDropping = false

    var body: some View {
        List {
            if draft.coordinate == nil {
                Text(WatchSessionModel.markerStoredMessage)
                    .font(.caption)
            }
            TextField(String(localized: "Title (optional)", table: "PointDrop"), text: $title)
            TextField(String(localized: "Remark (optional)", table: "PointDrop"), text: $remark)
            Button(String(localized: "Drop", table: "PointDrop", comment: "Button that places the point")) {
                guard !isDropping else { return }
                isDropping = true
                let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard model.storeMarker(
                    at: draft.coordinate,
                    kind: draft.kind,
                    title: trimmedTitle.isEmpty ? model.defaultPointTitle() : trimmedTitle,
                    remark: remark.trimmingCharacters(in: .whitespacesAndNewlines)
                ) else {
                    isDropping = false
                    locationUnavailable = true
                    return
                }
                onDrop()
                dismiss()
            }
            .disabled(isDropping)
            Button(String(localized: "Cancel", table: "PointDrop"), role: .cancel) { dismiss() }
        }
        .navigationTitle(String(localized: "Drop \(draft.kind.pointDropLabel)", table: "PointDrop", comment: "Screen title; %@ is the localized marker type (Friendly, Neutral, Unknown, Hostile)"))
        .alert(String(localized: "Unable to store marker", table: "PointDrop"), isPresented: $locationUnavailable) {
            Button(String(localized: "OK", table: "PointDrop"), role: .cancel) {}
        } message: {
            Text(model.offlineNotice ?? String(localized: "Unable to store marker details.", table: "PointDrop"))
        }
    }
}

private struct PointTypeSector: Shape {
    let start: Angle
    let end: Angle

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) * 0.49
        let inner = outer * 0.5
        var path = Path()
        path.move(to: CGPoint(x: center.x + outer * cos(start.radians), y: center.y + outer * sin(start.radians)))
        path.addArc(center: center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        path.addLine(to: CGPoint(x: center.x + inner * cos(end.radians), y: center.y + inner * sin(end.radians)))
        path.addArc(center: center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

private struct PointToolsView: View {
    @ObservedObject var model: WatchSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false
    @State private var showMarkers = false

    var body: some View {
        GeometryReader { geometry in
            VStack {
                Spacer(minLength: 4)
                Button { showMarkers = true } label: {
                    Text(String(localized: "Dropped Markers", table: "PointDrop"))
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: geometry.size.height * 0.2)
                        .background(Color(white: 0.26), in: Capsule())
                }
                Spacer(minLength: 4)
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.black)
                        .frame(width: min(58, geometry.size.height * 0.3), height: min(58, geometry.size.height * 0.3))
                        .background(Color(white: 0.8), in: Circle())
                }
                .accessibilityLabel(String(localized: "Back to point types", table: "PointDrop"))
                Spacer(minLength: 4)
                Button { confirmDelete = true } label: {
                    Text(String(localized: "Clear Last Marker", table: "PointDrop"))
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: geometry.size.height * 0.2)
                        .background(model.markers.isEmpty ? Color(white: 0.26) : .red, in: Capsule())
                }
                .disabled(model.markers.isEmpty)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
        }
        .background(.black)
        .foregroundStyle(.white)
        .buttonStyle(.plain)
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .navigationDestination(isPresented: $showMarkers) { PointListView(model: model) }
        .confirmationDialog(String(localized: "clear-last-marker-confirmation", defaultValue: "Clear last marker?", table: "PointDrop"), isPresented: $confirmDelete) {
            Button(String(localized: "Clear Last Marker", table: "PointDrop"), role: .destructive) {
                if let marker = model.markers.first { model.deleteMarker(id: marker.id) }
            }
        }
        .onAppear {
            #if DEBUG
            showMarkers = ProcessInfo.processInfo.arguments.contains("--preview-markers")
            #endif
        }
    }
}