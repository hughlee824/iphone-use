import Foundation

// Shared empty-field check. No implicit replace or append workflow.
public enum RunnerTextInput {
    // UIKit text views omit AX value after the last character is removed.
    // Only use this after a validated readable field has been cleared.
    public static func isCleared(_ value: Any?) -> Bool {
        value == nil || (value as? String)?.isEmpty == true
    }

}

// Public command names shared by host validation and Runner execution. The
// XCTest key constants themselves stay in the iPhone target.
public enum RunnerPressKey: String, CaseIterable {
    case `return`, backspace, left, right, upArrow = "up", down, tab, shiftTab = "shift-tab"
    case selectAll = "select-all", end
    public var modifiers: [String] {
        if self == .shiftTab { return ["shift"] }
        return [.selectAll, .end].contains(self) ? ["command"] : []
    }
}
