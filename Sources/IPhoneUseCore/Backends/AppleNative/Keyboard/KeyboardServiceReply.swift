import Foundation

// Root-channel notifications may be interleaved with an outstanding operation.
// The caller additionally checks clipboard identity or keyboard ownership.
enum KeyboardServiceReply {
    case inventory, registration, pasteboard(String)

    init(request: [String: Any]) throws {
        let payload = request["payload"] as? [String: Any]
        if payload?["connectedServices"] != nil {
            self = .inventory
        } else if payload?["createService"] != nil {
            self = .registration
        } else if let command = request["command"] as? String, ["PULL", "SET"].contains(command) {
            self = .pasteboard(command + "_REPLY")
        } else { throw KeyboardXPC.invalid }
    }

    func matches(_ value: [String: Any]) -> Bool {
        switch self {
        case .inventory: return value["connectedServices"] is [[String: Any]]
        case .registration: return value["serviceID"] is NSNumber
        case .pasteboard(let command): return value["command"] as? String == command
        }
    }
}
