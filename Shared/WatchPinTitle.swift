import Foundation

enum WatchPinTitle {
    static func trimmingTrailingWhitespace(_ title: String) -> String {
        String(title.reversed().drop(while: \.isWhitespace).reversed())
    }
}
