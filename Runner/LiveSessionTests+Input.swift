import IPhoneUseRunnerSupport
import Network
import XCTest
import Darwin

extension LiveSessionTests {

    @MainActor
    func perform(_ command: [String: Any]) throws -> [String: Any] {
        guard !inputSessionUncertain else {
            throw CommandError(
                "input_session_uncertain",
                message: "Close this session after unconfirmed event synthesis; do not replay")
        }
        guard let kind = command["kind"] as? String,
            ["tap", "double-tap", "long-press", "pinch", "swipe", "focus", "clear", "type", "press", "home"]
                .contains(kind),
            let expected = command["target"] as? [String: Any],
            let scope = expected["scope"] as? String
        else {
            throw CommandError("invalid_action")
        }
        commandReferences = observedReferences.take()
        let mode = command["mode"] as? String
        let text = command["text"] as? String
        let pressKey = (command["key"] as? String).flatMap(RunnerPressKey.init(rawValue:))
        try validateInput(kind: kind, pressKey: pressKey, text: text, mode: mode)
        guard expected["bundleId"] as? String == currentBundleID else {
            throw CommandError("app_changed", requiresObservation: true)
        }
        let (app, root) = try actionRoot(scope: scope)
        if kind == "home" { return try performHome(command, app: app, root: root) }
        if command["gesture"] != nil {
            return try performGesture(command, kind: kind, app: app, root: root)
        }
        let (target, liveSnapshot) = try actionTarget(expected, root: root)
        if ["tap", "double-tap", "long-press", "swipe"].contains(kind) {
            return try performElementGesture(command, kind: kind, target: target)
        }
        return try performInput(command, expected: expected, context: (app, root), selected: (target, liveSnapshot))
    }

    @MainActor
    private func performInput(
        _ command: [String: Any], expected: [String: Any],
        context: (XCUIApplication, XCUIElement), selected: (XCUIElement, XCUIElementSnapshot)
    ) throws -> [String: Any] {
        let (target, liveSnapshot) = selected
        let (app, root) = context
        let kind = command["kind"] as? String ?? ""
        let scope = expected["scope"] as? String ?? ""
        let text = command["text"] as? String
        let pressKey = (command["key"] as? String).flatMap(RunnerPressKey.init(rawValue:))
        try validateTextTarget(target, kind: kind)
        postInputContext = screenContext(app: app, root: root)
        let primitive = RunnerInputAction()
        inputAction = primitive
        let focused = try RunnerAXBinding.keyboardFocus(of: target).boolValue
        func current() throws -> (XCUIElement, XCUIElementSnapshot) {
            let (_, latestRoot) = try actionRoot(scope: scope)
            return try actionTarget(expected, root: latestRoot)
        }
        do {
            switch kind {
            case "focus":
                if !focused && !target.isHittable { throw CommandError("target_not_hittable") }
                try primitive.focus(isFocused: focused, event: { try self.event { target.tap() } }, verify: {
                    let (element, _) = try current()
                    return try RunnerAXBinding.keyboardFocus(of: element).boolValue
                })
            case "clear":
                try clear(primitive, target: target, snapshot: liveSnapshot, expected: expected) {
                    let (_, snapshot) = try current()
                    return RunnerTextInput.isCleared(snapshot.value)
                }
            case "type":
                try insert(text, target: target, primitive: primitive, focused: focused)
            case "press":
                var facts: [String: Any] = [:]
                try primitive.send(focused: focused) {
                    facts = try press(pressKey, target: target)
                }
                return facts
            default: throw CommandError("invalid_action")
            }
        } catch let failure as RunnerInputAction.Failure {
            throw CommandError(failure.rawValue, requiresObservation: true)
        }
        postInputTextFields = [ScreenRect(liveSnapshot.frame)]
        return ["kind": kind, "noOp": !primitive.attempted, "resultVerified": primitive.verification == "confirmed"]
    }

    @MainActor
    private func insert(_ text: String?, target: XCUIElement, primitive: RunnerInputAction, focused: Bool) throws {
        guard let text else { throw CommandError("invalid_text") }
        if text.contains("\n") && target.elementType != .textView {
            throw CommandError("multiline_requires_text_view")
        }
        try primitive.send(focused: focused) { try self.event { target.typeText(text) } }
    }

    @MainActor
    private func clear(
        _ primitive: RunnerInputAction, target: XCUIElement, snapshot: XCUIElementSnapshot,
        expected: [String: Any], verify: () throws -> Bool
    ) throws {
        let value = (expected["path"] as? [[String: Any]])?.last?["value"]
        try primitive.clear(
            state: .init(value: snapshot.value, secure: target.elementType == .secureTextField,
                         focused: try RunnerAXBinding.keyboardFocus(of: target).boolValue),
            expected: value is NSNull ? nil : value,
            event: { try self.event { target.typeText(XCUIKeyboardKey.delete.rawValue) } }, verify: verify)
    }

    private func validateInput(kind: String, pressKey: RunnerPressKey?, text: String?, mode: String?) throws {
        if kind == "press", pressKey == nil { throw CommandError("invalid_key") }
        if kind == "type" { try validateText(text, mode: mode) }
    }

    @MainActor
    private func validateTextTarget(_ target: XCUIElement, kind: String) throws {
        if ["focus", "clear", "type", "press"].contains(kind),
            ![XCUIElement.ElementType.textField, .secureTextField, .textView, .searchField].contains(
                target.elementType) {
            throw CommandError("not_text_input")
        }
    }

    private func validateText(_ text: String?, mode: String?) throws {
        guard mode == "insert", let text, text.utf8.count <= 4096, !text.isEmpty,
            text.unicodeScalars.allSatisfy({
                let value = $0.value
                return value == 10
                    || (value >= 32 && value != 127 && value != 133 && value != 0x2028 && value != 0x2029
                        && !(0xF700...0xF8FF).contains(value))
            })
        else { throw CommandError("invalid_text") }
    }

    @MainActor
    private func actionRoot(scope: String) throws -> (XCUIApplication, XCUIElement) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let systemAlerts = springboard.alerts
        let app: XCUIApplication
        let root: XCUIElement
        if scope == "systemAlert" {
            guard systemAlerts.count == 1 else {
                throw CommandError("system_alert_changed", requiresObservation: true)
            }
            app = springboard; root = systemAlerts.firstMatch
        } else {
            guard let currentApp, currentApp.state == .runningForeground, systemAlerts.count == 0 else {
                throw CommandError("app_context_changed", requiresObservation: true)
            }
            app = currentApp
            let alerts = app.alerts
            if scope == "appAlert", alerts.count == 1 {
                root = alerts.firstMatch
            } else if scope == "app", alerts.count == 0 {
                root = app
            } else {
                throw CommandError("app_alert_changed", requiresObservation: true)
            }
        }
        return (app, root)
    }

    @MainActor
    private func performHome(_ command: [String: Any], app: XCUIApplication, root: XCUIElement) throws
        -> [String: Any] {
        guard let raw = command["screenGuard"] as? [String: Any],
            let screenGuard = try? JSONDecoder().decode(
                ScreenGuard.self, from: JSONSerialization.data(withJSONObject: raw))
        else {
            throw CommandError("invalid_screen_guard")
        }
        let context = screenContext(app: app, root: root)
        guard screenGuard.context.matches(context) else {
            throw CommandError("screen_context_changed", requiresObservation: true)
        }
        try event { XCUIDevice.shared.press(.home) }
        // The next observation can be screenshot-only; never invent an App
        // or SpringBoard element target from a Home press acknowledgement.
        currentApp = nil; currentBundleID = nil
        return ["kind": "home", "homePressCompleted": true, "homeScreenConfirmed": false]
    }

    @MainActor
    private func actionTarget(_ expected: [String: Any], root: XCUIElement) throws
        -> (XCUIElement, XCUIElementSnapshot) {
        guard let path = expected["path"] as? [[String: Any]], !path.isEmpty else {
            throw CommandError("invalid_action")
        }
        func identityMatches(_ node: XCUIElementSnapshot, _ step: [String: Any]) throws -> Bool {
            let identity = try commandReferences.identity(for: step["identityToken"] as? String)
            return try identity.isEqual(RunnerAXBinding.identity(of: node))
        }
        do {
            let result = try RunnerAXTree.resolve(
                root: root, path: path, access: .init(snapshot: freshSnapshot, children: { $0.children },
                bind: { root, selected in
                    guard let element = try RunnerAXBinding.bind(
                        snapshot: selected, query: root.descendants(matching: .any)) as? XCUIElement
                    else { throw CommandError("target_binding_unavailable") }
                    return element
                }), sameIdentity: { first, second in
                    try RunnerAXBinding.identity(of: first).isEqual(RunnerAXBinding.identity(of: second))
                }, matches: { node, step in
                    try identityMatches(node, step) && step["type"] as? UInt == node.elementType.rawValue
                }, identityMatches: identityMatches)
            guard result.0.isEnabled else { throw CommandError("target_disabled") }
            return result
        } catch let failure as RunnerAXReferences<NSObject>.Failure {
            throw CommandError(failure.rawValue, requiresObservation: true)
        } catch let failure as RunnerAXTree.Failure {
            throw CommandError(failure.rawValue, requiresObservation: true)
        } catch let error as NSError where error.domain == "RunnerAXBinding" {
            throw CommandError("target_binding_unavailable", requiresObservation: true,
                               message: error.localizedDescription)
        }
    }

    @MainActor
    private func performElementGesture(_ command: [String: Any], kind: String, target: XCUIElement) throws
        -> [String: Any] {
        guard target.isHittable else { throw CommandError("target_not_hittable", requiresObservation: true) }
        switch kind {
        case "tap": try event { target.tap() }
        case "double-tap": try event { target.doubleTap() }
        case "long-press":
            guard let duration = command["duration"] as? Double, duration.isFinite, (0.5...5).contains(duration)
            else { throw CommandError("invalid_press_duration") }
            try event { target.press(forDuration: duration) }
            return ["kind": kind, "duration": duration, "targetBinding": "ax_identity"]
        case "swipe": return try swipeElement(target, command: command)
        default: throw CommandError("invalid_action")
        }
        return ["kind": kind, "targetBinding": "ax_identity"]
    }

    @MainActor
    private func swipeElement(_ target: XCUIElement, command: [String: Any]) throws -> [String: Any] {
        guard let direction = command["direction"] as? String, ["up", "down", "left", "right"].contains(direction),
            let raw = command["motion"] as? [String: Any],
            let motion = try? JSONDecoder().decode(SwipeMotion.self, from: JSONSerialization.data(withJSONObject: raw)),
            motion.valid else { throw CommandError("invalid_swipe_motion") }
        let vertical = ["up", "down"].contains(direction)
        let low = CGVector(dx: vertical ? 0.5 : 0.2, dy: vertical ? 0.2 : 0.5)
        let high = CGVector(dx: vertical ? 0.5 : 0.8, dy: vertical ? 0.8 : 0.5)
        let reverse = ["up", "left"].contains(direction)
        let from = target.coordinate(withNormalizedOffset: reverse ? high : low)
        let destination = target.coordinate(withNormalizedOffset: reverse ? low : high)
        let (_, scopeRoot) = try actionRoot(
            scope: (command["target"] as? [String: Any])?["scope"] as? String ?? "")
        guard scopeRoot.frame.contains(from.screenPoint), scopeRoot.frame.contains(destination.screenPoint) else {
            throw CommandError("target_not_visible", requiresObservation: true)
        }
        let distance = (vertical ? target.frame.height : target.frame.width) * 0.6
        guard distance.isFinite, distance > 0,
            distance / motion.velocity + motion.pressDuration + motion.holdDuration <= 10
        else { throw CommandError("swipe_duration_exceeded") }
        try event {
            from.press(forDuration: motion.pressDuration, thenDragTo: destination,
                       withVelocity: XCUIGestureVelocity(rawValue: CGFloat(motion.velocity)),
                       thenHoldForDuration: motion.holdDuration)
        }
        return ["kind": "swipe", "targetBinding": "ax_identity", "motion": motion.result]
    }

    @MainActor
    private func press(
        _ pressKey: RunnerPressKey?, target: XCUIElement
    ) throws -> [String: Any] {
        guard let pressKey else { throw CommandError("invalid_key") }
        let key = keyboardKey(pressKey)
        if pressKey == .return || pressKey == .backspace {
            // typeKey(Delete) can return without deleting on iOS. Use the
            // existing text-input path for Delete/Return; no focus tap.
            try event { target.typeText(key.rawValue) }
        } else {
            try event { target.typeKey(key.rawValue, modifierFlags: pressKey == .shiftTab ? .shift :
                    ([.selectAll, .end].contains(pressKey) ? .command : [])) }
        }
        return ["kind": "press", "key": pressKey.rawValue, "keyModifiers": pressKey.modifiers]
    }

    private func keyboardKey(_ pressKey: RunnerPressKey) -> XCUIKeyboardKey {
        let key: XCUIKeyboardKey
        switch pressKey {
        case .return: key = .return
        case .backspace: key = .delete
        case .left: key = .leftArrow
        case .right: key = .rightArrow
        case .upArrow: key = .upArrow
        case .down: key = .downArrow
        case .tab, .shiftTab: key = .tab
        case .selectAll: key = XCUIKeyboardKey(rawValue: "a")
        case .end: key = .downArrow
        }
        return key
    }

}
