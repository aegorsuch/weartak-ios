import SwiftUI

struct MOPPView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var selection: MOPPStatus

    init(settings: AppSettings) {
        self.settings = settings
        _selection = State(initialValue: settings.moppStatus)
    }

    var body: some View {
        List {
            LabeledContent(String(localized: "PPE Status", table: "WatchSettings"),
                value: settings.moppStatus.localizedLabel)
            Section(String(localized: "Select Status", table: "WatchSettings")) {
                ForEach(MOPPStatus.allCases) { status in
                    Button {
                        selection = status
                    } label: {
                        HStack {
                            Text(status.localizedLabel)
                            Spacer()
                            if selection == status {
                                Image(systemName: "checkmark").foregroundStyle(.blue)
                            }
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityAddTraits(selection == status ? .isSelected : [])
                    .accessibilityIdentifier("mopp-choice-\(status.rawValue)")
                }
            }
            .disabled(!settings.moppEnabled)
            Section {
                Button {
                    settings.moppStatus = selection
                    settings.moppSavedAt = Date()
                    dismiss()
                } label: {
                    Label(String(localized: "Save Status", table: "WatchSettings"), systemImage: "checkmark")
                }
                .disabled(!settings.moppEnabled || (selection == settings.moppStatus && settings.moppSavedAt != nil))
                .accessibilityIdentifier("mopp-save-status")
            } footer: {
                Text("Manual saved status. Shared with a connected supported Companion when enabled; not a command or sensor reading.",
                    tableName: "WatchSettings")
            }
        }
        .navigationTitle("MOPP")
    }
}

extension MOPPStatus {
    var localizedLabel: String {
        self == .none ? String(localized: "None", table: "WatchSettings") : "MOPP \(rawValue)"
    }
}

struct ProtectiveMaskIcon: View {
    var body: some View {
        ProtectiveMaskShape()
            .stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            .aspectRatio(1, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

private struct ProtectiveMaskShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + side * x, y: origin.y + side * y)
        }
        var path = Path()
        path.move(to: point(0.5, 0.08))
        path.addCurve(to: point(0.84, 0.4), control1: point(0.75, 0.08), control2: point(0.84, 0.2))
        path.addLine(to: point(0.79, 0.75))
        path.addQuadCurve(to: point(0.5, 0.94), control: point(0.7, 0.94))
        path.addQuadCurve(to: point(0.21, 0.75), control: point(0.3, 0.94))
        path.addLine(to: point(0.16, 0.4))
        path.addCurve(to: point(0.5, 0.08), control1: point(0.16, 0.2), control2: point(0.25, 0.08))
        path.closeSubpath()
        for x: CGFloat in [0.24, 0.55] {
            path.addRoundedRect(in: CGRect(origin: point(x, 0.29), size: CGSize(width: side * 0.21, height: side * 0.19)),
                                cornerSize: CGSize(width: side * 0.05, height: side * 0.05))
        }
        path.addEllipse(in: CGRect(origin: point(0.36, 0.58), size: CGSize(width: side * 0.28, height: side * 0.28)))
        path.move(to: point(0.43, 0.72))
        path.addLine(to: point(0.57, 0.72))
        path.move(to: point(0.5, 0.65))
        path.addLine(to: point(0.5, 0.79))
        return path
    }
}
