import CoreLocation
import Foundation

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
        precondition(MapCoordinateFormatter.dashboardLines(
            CLLocationCoordinate2D(latitude: 91, longitude: 0), mgrs: false) == nil)
        precondition(MapCoordinateFormatter.dashboardLines(
            CLLocationCoordinate2D(latitude: 85, longitude: 0), mgrs: true) == nil)
        print("PASS: full five-decimal coordinates and one-meter MGRS dashboard/picker precision")
    }
}
