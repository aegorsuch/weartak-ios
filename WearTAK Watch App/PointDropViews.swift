import SwiftUI

struct PointTypePickerView: View {
    @ObservedObject var model: WatchSessionModel
    let onSelect: (MarkerKind) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var showTools = false
    @State private var locationUnavailable = false
    @State private var isSelecting = false

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height) - 10
            ZStack {
                sector(.hostile, angle: -90, diameter: diameter)
                sector(.neutral, angle: -180, diameter: diameter)
                sector(.friendly, angle: 0, diameter: diameter)
                sector(.unknown, angle: 90, diameter: diameter)
                let caption = Array("Hold for more")
                ForEach(caption.indices, id: \.self) { index in
                    let angle = -160.0 + 140.0 * Double(index) / Double(caption.count - 1)
                    Text(String(caption[index]))
                        .font(.system(size: 11))
                        .rotationEffect(.degrees(angle + 90))
                        .position(x: diameter * (0.5 + 0.20 * cos(angle * .pi / 180)),
                                  y: diameter * (0.5 + 0.20 * sin(angle * .pi / 180)))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
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
                    .accessibilityLabel("Cancel point drop")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { dismiss() }
                    .accessibilityAction(named: "Marker options") { showTools = true }
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
        .alert("Location unavailable", isPresented: $locationUnavailable) {
            Button("OK", role: .cancel) {}
        }
        .onAppear {
            #if DEBUG
            showTools = ProcessInfo.processInfo.arguments.contains("--preview-marker-tools")
            #endif
        }
    }

    private func sector(_ kind: MarkerKind, angle: Double, diameter: CGFloat) -> some View {
        let shape = PointTypeSector(start: .degrees(angle - 43), end: .degrees(angle + 43))
        return Button {
            guard !isSelecting else { return }
            isSelecting = true
            if onSelect(kind) { dismiss() }
            else {
                isSelecting = false
                locationUnavailable = true
            }
        } label: {
            shape.fill(Color(white: 0.26))
                .overlay {
                    VStack(spacing: 2) {
                        MapPointSymbol(kind: kind)
                            .frame(width: 24, height: 24)
                        Text(kind.rawValue).font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .frame(width: diameter * 0.37, height: 40)
                    .position(x: diameter * (0.5 + 0.34 * cos(angle * .pi / 180)),
                              y: diameter * (0.5 + 0.38 * sin(angle * .pi / 180)))
                }
                .contentShape(shape)
        }
        .disabled(isSelecting)
        .accessibilityLabel("Drop \(kind.rawValue) point")
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
                    Text("Dropped Markers")
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
                .accessibilityLabel("Back to point types")
                Spacer(minLength: 4)
                Button { confirmDelete = true } label: {
                    Text("Clear Last Marker")
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
        .confirmationDialog("Clear last marker?", isPresented: $confirmDelete) {
            Button("Clear Last Marker", role: .destructive) {
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