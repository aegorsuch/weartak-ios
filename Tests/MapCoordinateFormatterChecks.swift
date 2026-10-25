import CoreLocation
import Foundation
#if canImport(AppKit)
import AppKit
#endif

@main
struct MapCoordinateFormatterChecks {
    static func main() {
        let coordinate = CLLocationCoordinate2D(latitude: 38.123456, longitude: -77.987654)
        let degrees = MapCoordinateFormatter.dashboardLines(coordinate, mgrs: false)!
        precondition(degrees.0 == "38.12345N" && degrees.1 == "77.98765W")
        let small = MapCoordinateFormatter.dashboardLines(
            CLLocationCoordinate2D(latitude: -0.000019, longitude: 0.000029), mgrs: false)!
        precondition(small.0 == "0.00001S" && small.1 == "0.00002E")
        let grid = MapCoordinateFormatter.dashboardLines(coordinate, mgrs: true)!
        precondition("\(grid.0) \(grid.1)" == MapCoordinateFormatter.mgrs(coordinate))
        let numbers = grid.1.split(separator: " ")
        precondition(numbers.count == 2 && numbers.allSatisfy { $0.count == 5 })
        precondition(MapCoordinateFormatter.dashboardValue(coordinate, mgrs: true) == "\(grid.0) \(grid.1)")
        precondition(MapCoordinateFormatter.dashboardValue(coordinate, mgrs: false) == "38.12345N / 77.98765W")
        var values: [String] = []
        for fix in [coordinate, CLLocationCoordinate2D(latitude: -79.99999, longitude: -179.99999),
                    CLLocationCoordinate2D(latitude: 83.99999, longitude: 179.99999),
                    CLLocationCoordinate2D(latitude: -0.000019, longitude: 0.000029)] {
            for mgrs in [false, true] {
                let value = MapCoordinateFormatter.dashboardValue(fix, mgrs: mgrs)!
                precondition(!value.contains("\n") && !value.contains("\u{2026}"))
                let lines = MapCoordinateFormatter.dashboardLines(fix, mgrs: mgrs)!
                precondition(value == (mgrs ? "\(lines.0) \(lines.1)" : "\(lines.0) / \(lines.1)"))
                if mgrs { precondition(value == MapCoordinateFormatter.mgrs(fix)) }
                values.append(value)
            }
        }
        #if canImport(AppKit)
        // Native glyph-width budget, not a watchOS rendering or Android text-scale equivalence.
        for size: CGFloat in [13, 15, 20, 26] {
            let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
            for width: CGFloat in [156, 162, 176, 184, 198, 205] {
                let available = width - 8 - 28 * 2 - 6 * 2 - 8
                precondition(available >= 44)
                for value in values {
                    let measured = (value as NSString).size(withAttributes: [.font: font]).width
                    let scale = min(1, available / measured)
                    precondition(scale >= 0.2 && measured * scale <= available + 0.001)
                }
            }
        }
        print("PASS: native single-line glyph-width budgets at 156-205pt headers and 13-26pt fonts; no rendered-device claim")
        #endif
        precondition(MapCoordinateFormatter.dashboardLines(
            CLLocationCoordinate2D(latitude: 91, longitude: 0), mgrs: false) == nil)
        precondition(MapCoordinateFormatter.dashboardLines(
            CLLocationCoordinate2D(latitude: 85, longitude: 0), mgrs: true) == nil)
        precondition(MapCoordinateFormatter.dashboardValue(
            CLLocationCoordinate2D(latitude: 91, longitude: 0), mgrs: false) == nil)
        print("PASS: full five-decimal coordinates and one-meter MGRS dashboard/picker precision")
    }
}
