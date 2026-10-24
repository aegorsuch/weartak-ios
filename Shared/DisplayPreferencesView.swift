#if canImport(SwiftUI)
import SwiftUI

struct DisplayPreferencesView: View {
    @AppStorage(DistanceUnits.storageKey) private var units = DistanceUnits.metric

    var body: some View {
        List {
            Picker("Units", selection: $units) {
                ForEach(DistanceUnits.allCases) { value in
                    Text(value.title).tag(value)
                }
            }
        }
        .navigationTitle("Display Preferences")
    }
}
#endif
