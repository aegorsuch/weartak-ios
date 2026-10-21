import Foundation

/// Guards against string catalogs saved through a lossy encoding, which turns every non-ASCII character
/// of a translation into a literal "?" (for example "Zakázáno" becoming "Zak?z?no").
@main
struct StringCatalogEncodingChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
            ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else {
            preconditionFailure("Cannot enumerate \(root.path)")
        }
        var catalogs = 0
        var failures: [String] = []
        for case let url as URL in files {
            if url.lastPathComponent == "build" || url.lastPathComponent == "DerivedData" {
                files.skipDescendants()
                continue
            }
            guard url.pathExtension == "xcstrings" else { continue }
            catalogs += 1
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            guard let catalog = object as? [String: Any], let strings = catalog["strings"] as? [String: Any] else {
                failures.append("\(url.lastPathComponent): not a string catalog")
                continue
            }
            let source = catalog["sourceLanguage"] as? String ?? "en"
            for (key, entry) in strings {
                let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
                let sourceUnit = (localizations[source] as? [String: Any])?["stringUnit"] as? [String: Any]
                let english = sourceUnit?["value"] as? String ?? key
                for (language, localization) in localizations where language != source {
                    for value in stringUnitValues(localization)
                    where questionMarks(value) > questionMarks(english) {
                        failures.append("\(url.lastPathComponent) [\(language)] \(key): \(value)")
                    }
                }
            }
        }
        precondition(catalogs > 0, "No .xcstrings catalogs found under \(root.path)")
        guard failures.isEmpty else {
            for failure in failures.sorted() {
                FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
            }
            FileHandle.standardError.write(Data(
                "\(failures.count) localized values have more '?' than their English source (lossy encoding?)\n".utf8))
            exit(1)
        }
        print("PASS: \(catalogs) string catalogs have no '?'-corrupted translations")
    }

    private static func questionMarks(_ value: String) -> Int {
        value.reduce(0) { $1 == "?" ? $0 + 1 : $0 }
    }

    /// Collects the plain value plus any plural/device variation values beneath a localization.
    private static func stringUnitValues(_ node: Any?) -> [String] {
        if let array = node as? [Any] { return array.flatMap { stringUnitValues($0) } }
        guard let dictionary = node as? [String: Any] else { return [] }
        var values: [String] = []
        if let value = (dictionary["stringUnit"] as? [String: Any])?["value"] as? String {
            values.append(value)
        }
        for (name, child) in dictionary where name != "stringUnit" {
            values += stringUnitValues(child)
        }
        return values
    }
}
