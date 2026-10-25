import Foundation

@main
struct DashboardMetricChecks {
    static func main() throws {
        precondition(DashboardMetric.allCases == [.exertion, .heartRate, .latLon, .mgrs])
        precondition(DashboardMetric.heartRate.symbol == "heart.fill")
        let english: [DashboardMetric: String] = [
            .exertion: "Exertion", .heartRate: "Heart Rate", .latLon: "Lat/Long", .mgrs: "MGRS"
        ]
        precondition(DashboardMetric.sorted { english[$0]! } == [.exertion, .heartRate, .latLon, .mgrs])
        precondition(DashboardMetric.sorted { $0 == .mgrs ? "AAA" : english[$0]! }.first == .mgrs)
        precondition(DashboardMetric.restored("Lat/Lon") == .latLon)
        precondition(DashboardMetric.restored("Lat/Long") == .latLon)
        precondition(DashboardMetric.restored("Heart Rate") == .heartRate)
        precondition(DashboardMetric.restored("removed-choice") == .exertion)
        precondition(DashboardMetric.restored(nil) == .exertion)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for metric in [DashboardMetric.exertion, .heartRate] {
            for date in [now, now.addingTimeInterval(-300), now.addingTimeInterval(1), nil] {
                precondition(metric.reading(monitoringEnabled: false, value: 80, measuredAt: date, now: now) == .disabled)
            }
            precondition(metric.reading(monitoringEnabled: true, value: 80, measuredAt: now, now: now) == .value(80))
            precondition(metric.reading(monitoringEnabled: true, value: 80,
                measuredAt: now.addingTimeInterval(-61), now: now) == .unavailable)
            precondition(metric.reading(monitoringEnabled: true, value: 80,
                measuredAt: now.addingTimeInterval(1), now: now) == .unavailable)
            precondition(metric.reading(monitoringEnabled: true, value: nil, measuredAt: now, now: now) == .unavailable)
        }
        for metric in [DashboardMetric.latLon, .mgrs] {
            precondition(metric.isCoordinate)
            precondition(metric.reading(monitoringEnabled: false, value: nil, measuredAt: nil, now: now) != .disabled)
        }
        let source = try String(contentsOfFile: "WearTAK Watch App/ContentView.swift", encoding: .utf8)
        let selector = source.components(separatedBy: "private struct DashboardMetricPreferencesView: View {")[1]
            .components(separatedBy: "private struct DashboardLocationIndicator: View {")[0]
        precondition(selector.contains("PhysiologicalControlsView(settings: settings)"))
        precondition(selector.contains("showAlertThresholds = true"))
        precondition(selector.contains("PhysiologicalAlertsView(settings: settings)"))
        precondition(!selector.contains(".disabled(") && !selector.contains("settings.physiologicalAlertsEnabled ="))
        precondition(!selector.contains("Image(systemName: metric.symbol)"))
        precondition(selector.contains("TimelineView(.periodic") && selector.contains("minimumScaleFactor"))
        precondition(selector.contains("await monitor.startViewing()"))
        precondition(selector.contains("metric.reading(monitoringEnabled:"))
        let settings = try String(contentsOfFile: "WearTAK Watch App/SettingsView.swift", encoding: .utf8)
        let controls = settings.components(separatedBy: "struct PhysiologicalControlsView: View {")[1]
            .components(separatedBy: "struct PhysiologicalAlertsView: View {")[0]
        precondition(controls.contains("isOn: $settings.physiologicalMonitoringEnabled"))
        precondition(controls.contains("isOn: $settings.physiologicalAlertsEnabled"))
        precondition(controls.range(of: "physiologicalAlertsEnabled")!.lowerBound <
            controls.range(of: "physiologicalMonitoringEnabled")!.lowerBound)
        precondition(controls.components(separatedBy: ".lineLimit(1)").count == 3)
        precondition(controls.components(separatedBy: ".minimumScaleFactor(0.4)").count == 3)
        precondition(controls.components(separatedBy: ".frame(minHeight: 44)").count == 3)
        precondition(controls.components(separatedBy: ".accessibilityLabel(").count == 4)
        precondition(!controls.contains(".truncationMode") && !controls.contains(".dynamicTypeSize"))
        precondition(!controls.contains(".disabled(") && controls.contains("44, height: 44"))
        precondition(settings.components(separatedBy: "PhysiologicalControlsView(settings: settings)").count == 3)
        let coordinates = source.components(separatedBy: "if settings.dashboardMetric.isCoordinate {")[1]
            .components(separatedBy: "} else {")[0]
        precondition(!coordinates.contains("Image(") && coordinates.contains("dashboardValue"))
        precondition(!coordinates.contains("VStack("))
        precondition(coordinates.contains(".lineLimit(1)") && coordinates.contains(".minimumScaleFactor(0.2)"))
        precondition(!coordinates.contains(".truncationMode") && !coordinates.contains(".dynamicTypeSize"))
        let header = source.components(separatedBy: "private func statusHeader(small: Bool) -> some View {")[1]
            .components(separatedBy: "private var actionRow:")[0]
        precondition(header.contains(".frame(maxWidth: .infinity, minHeight: 44)"))
        precondition(header.contains(".contentShape(Rectangle())") && !header.contains("Spacer("))
        precondition(header.range(of: "DashboardMetricPreferencesView(")!.lowerBound <
            header.range(of: "if settings.dashboardMetric.isCoordinate")!.lowerBound)
        precondition(header.contains("Select metric. \\(metricAccessibilityText)"))
        var readiness = OutboundRouteReadiness()
        precondition(!readiness.update([]))
        precondition(readiness.update(["server"]))
        precondition(!readiness.update(["server"]))
        precondition(readiness.update(["server", "ditto"]))
        precondition(!readiness.update(["ditto"]))
        precondition(!readiness.update([]))
        precondition(readiness.update(["ditto"]))
        let phone = try String(contentsOfFile: "WearTAK Companion/PhoneBridgeModel.swift", encoding: .utf8)
        let announcement = phone.components(separatedBy: "private func refreshOutboundAnnouncements() {")[1]
            .components(separatedBy: "private func reportPhoneFix(")[0]
        precondition(announcement.contains("outboundReadiness.update(routes)"))
        precondition(announcement.contains("requestSelfPosition(allowLastKnown: false)"))
        precondition(!announcement.contains("chat") && !announcement.contains("emergency"))
        precondition(phone.contains("if self.connectivityAnnouncementPending, let fix"))
        let watch = try String(contentsOfFile: "WearTAK Watch App/WatchSessionModel.swift", encoding: .utf8)
        precondition(watch.contains("self.refreshDittoAnnouncement()"))
        precondition(watch.contains("revision == dittoAnnouncementRevision"))
        let locationLink = source.components(separatedBy: "ReportingStrategyView(settings: settings)")[1]
            .components(separatedBy: "dashboard-reporting-rates")[0]
        precondition(locationLink.contains("DashboardLocationIndicator(model: model, small: small)"))
        precondition(!locationLink.contains("setEnabled") && !locationLink.contains("Toggle("))
        let catalogue = try JSONSerialization.jsonObject(with:
            Data(contentsOf: URL(fileURLWithPath: "WearTAK Watch App/WatchMain.xcstrings"))) as! [String: Any]
        precondition((catalogue["strings"] as! [String: Any])["Lat/Long"] != nil)
        print("PASS: supported localized metric list, persisted values, Disabled precedence, freshness, independent controls and reporting navigation")
    }
}
