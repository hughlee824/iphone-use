import Foundation
import IPhoneUseRunnerSupport

// Executes LiveSessionTests.perform from Runner/LiveSessionTests+Input.swift.
// The platform fixture fails immediately on any access to a removed element.
@main
struct InputActionTests {
    @MainActor
    static func main() throws {
        try focusTransitions()
        try failures()
        try clearValues()
        print("Runner input runtime regressions passed: identity, focus transitions, nil clear, no replay")
    }

    @MainActor
    private static func fixture() -> (LiveSessionTests, [XCUIElement]) {
        let runner = LiveSessionTests()
        let app = XCUIApplication(bundleIdentifier: "fixture")
        let first = XCUIElement(), second = XCUIElement()
        first.focused = true
        second.value = "neighbor"
        app.children = [first, second]
        runner.currentApp = app
        return (runner, [first, second])
    }

    @MainActor
    private static func command(
        _ runner: LiveSessionTests, _ target: XCUIElement, kind: String, key: String? = nil
    ) -> [String: Any] {
        runner.observedReferences = RunnerAXReferences()
        let app = runner.currentApp!
        let path = [app, target].enumerated().map { index, element -> [String: Any] in
            ["identityToken": runner.observedReferences.register(element.identity),
             "type": element.elementType.rawValue, "childIndex": index == 0 ? 0 : app.children.firstIndex {
                 $0 === target
             }!, "value": element.value ?? NSNull()]
        }
        var command: [String: Any] = [
            "kind": kind, "target": ["bundleId": "fixture", "scope": "app", "path": path]
        ]
        command["key"] = key
        if kind == "type" { command["mode"] = "insert"; command["text"] = "suffix" }
        return command
    }

    @MainActor
    private static func focusTransitions() throws {
        for key in ["tab", "shift-tab", "return"] {
            let (runner, fields) = fixture()
            let first = fields[0], second = fields[1]
            let request = command(runner, first, kind: "press", key: key)
            first.onEvent = { _ in
                first.focused = false; second.focused = true
                if key == "return" {
                    first.removed = true
                    runner.currentApp!.children = [second]
                }
            }
            let result = try runner.perform(request)
            precondition(result["key"] as? String == key)
            precondition(runner.events == 1 && runner.inputAction?.acknowledged == true)
            precondition(!first.focused && second.focused && second.value as? String == "neighbor")
            if !first.removed {
                do {
                    _ = try runner.perform(command(runner, first, kind: "type"))
                    preconditionFailure("Typing into old focus must reject")
                } catch let error as CommandError { precondition(error.code == "keyboard_focus_required") }
                precondition(runner.events == 1)
            }
            second.onEvent = { text in second.value = "neighbor" + text }
            _ = try runner.perform(command(runner, second, kind: "type"))
            precondition(runner.events == 2 && second.value as? String == "neighborsuffix")
        }
        let (runner, fields) = fixture()
        let first = fields[0], second = fields[1]
        second.onEvent = { _ in first.focused = false; second.focused = true }
        _ = try runner.perform(command(runner, second, kind: "focus"))
        precondition(runner.events == 1 && runner.inputAction?.verification == "confirmed")
        _ = try runner.perform(command(runner, second, kind: "focus"))
        precondition(runner.events == 1 && runner.inputAction?.attempted == false)
    }

    @MainActor
    private static func failures() throws {
        for kind in ["focus", "clear", "type", "press"] {
            let (runner, fields) = fixture()
            let first = fields[0]
            if kind == "focus" { first.focused = false }
            runner.failEvent = true
            let request = command(runner, first, kind: kind, key: kind == "press" ? "select-all" : nil)
            do { _ = try runner.perform(request); preconditionFailure("Expected event failure") } catch {}
            precondition(runner.events == 1 && runner.executionStarted)
            precondition(runner.inputAction?.attempted == true && runner.inputAction?.acknowledged == false)
            // An explicit duplicate with the consumed reference cannot dispatch again.
            do { _ = try runner.perform(request); preconditionFailure("Expected stale reference") } catch {}
            precondition(runner.events == 1)
        }
        for kind in ["focus", "clear"] {
            let (runner, fields) = fixture()
            let first = fields[0]
            if kind == "focus" { first.focused = false }
            runner.failSnapshotAfterEvent = true
            _ = try runner.perform(command(runner, first, kind: kind))
            precondition(runner.events == 1 && runner.inputAction?.acknowledged == true)
            precondition(runner.inputAction?.verification == "unavailable")
        }
        let (runner, fields) = fixture()
        let first = fields[0]
        first.focused = false
        first.onEvent = { _ in first.removed = true; runner.currentApp!.children = [] }
        _ = try runner.perform(command(runner, first, kind: "focus"))
        precondition(runner.events == 1 && runner.inputAction?.verification == "unavailable")
    }

    @MainActor
    private static func clearValues() throws {
        let (runner, fields) = fixture()
        let first = fields[0], second = fields[1]
        first.value = nil
        do {
            _ = try runner.perform(command(runner, first, kind: "clear"))
            preconditionFailure("Unknown value cannot mean empty")
        } catch let error as CommandError { precondition(error.code == "clear_value_unavailable") }
        precondition(runner.events == 0 && !runner.executionStarted)
        first.value = ""
        _ = try runner.perform(command(runner, first, kind: "clear"))
        precondition(runner.events == 0 && runner.inputAction?.verification == "confirmed")
        first.value = "old"
        first.onEvent = { key in precondition(key == "delete"); first.value = nil }
        _ = try runner.perform(command(runner, first, kind: "clear"))
        precondition(runner.events == 1 && runner.inputAction?.verification == "confirmed")
        precondition(second.value as? String == "neighbor")
    }
}
