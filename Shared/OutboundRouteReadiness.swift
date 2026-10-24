import Foundation

/// Only a newly usable route requests a current position; repeated status updates do not.
struct OutboundRouteReadiness {
    private var usable = Set<String>()

    mutating func update(_ routes: Set<String>) -> Bool {
        let added = !routes.subtracting(usable).isEmpty
        usable = routes
        return added
    }
}
