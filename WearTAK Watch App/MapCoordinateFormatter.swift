import CoreLocation
import Foundation

enum MapCoordinateFormatter {
    private static let latitudeBands = "CDEFGHJKLMNPQRSTUVWX"
    private static let directions = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

    static func droppedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func cardinalDirection(_ bearing: Double) -> String {
        let normalized = bearing.truncatingRemainder(dividingBy: 360)
        let index = Int((normalized + 11.25) / 22.5) % directions.count
        return directions[index]
    }

    static func mgrs(_ coordinate: CLLocationCoordinate2D) -> String? {
        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        guard CLLocationCoordinate2DIsValid(coordinate), (-80...84).contains(latitude) else { return nil }

        var zone = min(Int(floor((longitude + 180) / 6)) + 1, 60)
        if (56..<64).contains(latitude), (3..<12).contains(longitude) {
            zone = 32
        } else if (72..<84).contains(latitude) {
            if (0..<9).contains(longitude) { zone = 31 }
            else if (9..<21).contains(longitude) { zone = 33 }
            else if (21..<33).contains(longitude) { zone = 35 }
            else if (33..<42).contains(longitude) { zone = 37 }
        }

        let bandIndex = min(max(Int(floor((latitude + 80) / 8)), 0), 19)
        let band = latitudeBands[latitudeBands.index(latitudeBands.startIndex, offsetBy: bandIndex)]
        let (easting, northing) = utm(latitude: latitude, longitude: longitude, zone: zone)
        let column = min(max(Int(floor(easting / 100_000)), 1), 8)
        let row = Int(floor(northing / 100_000)) % 20
        let eastingSets = ["ABCDEFGH", "JKLMNPQR", "STUVWXYZ"]
        let northingSets = ["ABCDEFGHJKLMNPQRSTUV", "FGHJKLMNPQRSTUVABCDE"]
        let eastingLetters = eastingSets[(zone - 1) % 3]
        let northingLetters = northingSets[(zone - 1) % 2]
        let eastingLetter = eastingLetters[eastingLetters.index(eastingLetters.startIndex, offsetBy: column - 1)]
        let northingLetter = northingLetters[northingLetters.index(northingLetters.startIndex, offsetBy: row)]
        let zoneText = String(format: "%02d", zone)
        let eastingText = String(format: "%05d", Int(easting) % 100_000)
        let northingText = String(format: "%05d", Int(northing) % 100_000)
        return "\(zoneText)\(band) \(eastingLetter)\(northingLetter) \(eastingText) \(northingText)"
    }

    private static func utm(latitude: Double, longitude: Double, zone: Int) -> (Double, Double) {
        let semiMajorAxis = 6_378_137.0
        let eccentricitySquared = 0.00669438
        let scale = 0.9996
        let latitudeRadians = latitude * .pi / 180
        let longitudeRadians = longitude * .pi / 180
        let centralLongitude = (Double(zone) - 1) * 6 - 180 + 3
        let longitudeOffset = longitudeRadians - centralLongitude * .pi / 180
        let eccentricityPrimeSquared = eccentricitySquared / (1 - eccentricitySquared)
        let sineLatitude = sin(latitudeRadians)
        let cosineLatitude = cos(latitudeRadians)
        let tangentLatitude = tan(latitudeRadians)
        let n = semiMajorAxis / sqrt(1 - eccentricitySquared * sineLatitude * sineLatitude)
        let t = tangentLatitude * tangentLatitude
        let c = eccentricityPrimeSquared * cosineLatitude * cosineLatitude
        let a = cosineLatitude * longitudeOffset
        let eccentricityFourth = eccentricitySquared * eccentricitySquared
        let eccentricitySixth = eccentricityFourth * eccentricitySquared
        let meridionalArc = semiMajorAxis * (
            (1 - eccentricitySquared / 4 - 3 * eccentricityFourth / 64 - 5 * eccentricitySixth / 256) * latitudeRadians
                - (3 * eccentricitySquared / 8 + 3 * eccentricityFourth / 32 + 45 * eccentricitySixth / 1024) * sin(2 * latitudeRadians)
                + (15 * eccentricityFourth / 256 + 45 * eccentricitySixth / 1024) * sin(4 * latitudeRadians)
                - (35 * eccentricitySixth / 3072) * sin(6 * latitudeRadians)
        )
        let easting = scale * n * (
            a + (1 - t + c) * pow(a, 3) / 6
                + (5 - 18 * t + t * t + 72 * c - 58 * eccentricityPrimeSquared) * pow(a, 5) / 120
        ) + 500_000
        var northing = scale * (
            meridionalArc + n * tangentLatitude * (
                a * a / 2 + (5 - t + 9 * c + 4 * c * c) * pow(a, 4) / 24
                    + (61 - 58 * t + t * t + 600 * c - 330 * eccentricityPrimeSquared) * pow(a, 6) / 720
            )
        )
        if latitude < 0 { northing += 10_000_000 }
        return (easting, northing)
    }
}
