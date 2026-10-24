import Foundation

@main
struct DashboardMetricChecks {
    static func main() throws {
        precondition(DashboardMetric.allCases == [.exertion, .heartRate, .latLon, .mgrs])
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
        precondition(selector.contains("Toggle(String(localized: \"Alerts\""))
        precondition(selector.contains("isOn: $settings.physiologicalAlertsEnabled"))
        precondition(selector.contains("isOn: $settings.physiologicalMonitoringEnabled"))
        precondition(selector.contains("showAlertThresholds = true"))
        precondition(selector.contains("PhysiologicalAlertsView(settings: settings)"))
        precondition(!selector.contains(".disabled(") && !selector.contains("settings.physiologicalAlertsEnabled ="))
        precondition(!selector.contains("Image(systemName: metric.symbol)") && !selector.contains("startViewing"))
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
