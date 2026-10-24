struct DataSyncRequestGate {
    private(set) var revision = 0

    mutating func invalidate() { revision &+= 1 }

    func accepts(_ token: Int, enabled: Bool) -> Bool {
        enabled && token == revision
    }
}
