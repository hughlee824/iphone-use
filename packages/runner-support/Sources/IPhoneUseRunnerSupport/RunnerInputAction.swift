import Foundation

// One explicit primitive, never a focus/clear/type workflow. State reads may
// fail after an acknowledged event without changing its execution facts.
public final class RunnerInputAction {
    public enum Failure: String, Error {
        case alreadyAttempted = "input_already_attempted"
        case focusRequired = "keyboard_focus_required"
        case valueChanged = "text_value_changed"
        case valueUnavailable = "clear_value_unavailable"
    }
    public private(set) var attempted = false
    public private(set) var acknowledged = false
    public private(set) var verification = "not_requested"
    public private(set) var verificationError: String?

    public init() {}

    public var facts: [String: Any] {
        var result: [String: Any] = [
            "eventAttempted": attempted, "eventAcknowledged": acknowledged,
            "verification": verification, "automaticReplayAllowed": false
        ]
        result["verificationError"] = verificationError
        return result
    }

    public func send(focused: Bool, event: () throws -> Void) throws {
        guard !attempted else { throw Failure.alreadyAttempted }
        guard focused else { throw Failure.focusRequired }
        attempted = true
        try event()
        acknowledged = true
    }

    public func focus(isFocused: Bool, event: () throws -> Void, verify: () throws -> Bool) throws {
        guard !attempted else { throw Failure.alreadyAttempted }
        if isFocused { verification = "confirmed"; return }
        attempted = true
        try event()
        acknowledged = true
        check(verify)
    }

    public struct ClearState {
        public let value: Any?
        public let secure: Bool
        public let focused: Bool
        public init(value: Any?, secure: Bool, focused: Bool) {
            self.value = value; self.secure = secure; self.focused = focused
        }
    }

    public func clear(
        state: ClearState, expected: Any?,
        event: () throws -> Void, verify: () throws -> Bool
    ) throws {
        guard !attempted else { throw Failure.alreadyAttempted }
        // A missing pre-input AX value is not evidence that the field is empty.
        // Nil is only accepted by the post-delete check of a previously readable field.
        guard !state.secure, let value = state.value as? String else { throw Failure.valueUnavailable }
        guard let expected = expected as? String, value == expected else { throw Failure.valueChanged }
        guard state.focused else { throw Failure.focusRequired }
        if value.isEmpty { verification = "confirmed"; return }
        // The agent explicitly selects all and observes before clear. Delete
        // exactly once; incomplete selection never triggers more deletion.
        try send(focused: state.focused, event: event)
        check(verify)
    }

    private func check(_ read: () throws -> Bool) {
        do { verification = try read() ? "confirmed" : "unconfirmed" } catch {
            verification = "unavailable"
            // Do not include platform exceptions, AX labels or text values.
            verificationError = "post_action_validation_unavailable"
        }
    }
}
