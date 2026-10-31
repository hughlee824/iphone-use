import Foundation

enum NativePreviewDisplay {
    // Display topology is independent from permission to automate the UI.
    // A locked/waking screen may still have a valid system-provided video feed.
    static func read(_ operation: ([String]) throws -> [String: Any]) throws -> NativeDisplay {
        try NativeDisplay(operation(["device", "info", "displays"]))
    }
}
