import Foundation
import IPhoneUseRunnerSupport

extension AppleInputAttempt {
    func run(onInputStarted: @escaping () -> Void) throws -> [String: Any] {
        do { return try perform(onInputStarted: onInputStarted) } catch {
            guard focusTapQueued else { throw error }
            let failure = error as? ActionFailure
            var facts = failure?.result ?? [:]
            facts["focusTapQueued"] = true
            throw ActionFailure(code: failure?.code ?? (error as? IPhoneUseError)?.code ?? "native_input_uncertain",
                                description: String(describing: error), possiblyExecuted: true,
                                requiresObservation: true, result: facts, rejectedCapture: failure?.rejectedCapture)
        }
    }

    // The initial point is used only to request focus. Once focused, the editor may move.
    func prepareSemanticFocus(onInputStarted: @escaping () -> Void) throws {
        guard let editor = target.textEditor, let source = target.textSource else {
            throw focusFailure("Observe a unique, focused native text editor before typing")
        }
        if editor.sameEditor(as: NativeTextResponder(source)) { return }
        guard let index = action.reference.node, source.nodes.indices.contains(index) else {
            throw focusFailure("The original observation does not identify the focused editor")
        }
        let selected = source.nodes[index]
        let rect = editor.field.cgRect
        guard selected.attributes["visible"] as? Bool == true, selected.enabled != false,
            screenGuard.context.screen.cgRect.contains(rect) else {
            throw focusFailure("Observe a visible editor before requesting focus")
        }
        let point = CGPoint(x: rect.midX, y: rect.midY)
        let budget = NativeCaptureBudget(requestDeadline: timing.dispatchDeadline)
        try hid.prepare(displayUniqueID: target.context["displayUniqueID"] as? String)
        let frame = try textFocusFrame(budget: budget, hit: point)
        if editor.sameEditor(as: NativeTextResponder(frame)) { return }
        guard editor == NativeTextResponder(frame, selecting: selected),
            let collection = frame.metadata["axCollection"] as? [String: Any],
            let hit = collection["focusHit"] as? [String: Any],
            hit["pid"] as? Int == editor.pid, hit["objectID"] as? String == editor.objectID,
            hit["x"] as? Double == point.x, hit["y"] as? Double == point.y,
            try screenGuard.check(png: frame.screenshot, context: screenGuard.context).accepted else {
            throw focusFailure("The focus point no longer matches the observed editor", frame)
        }
        let mapped = try NativeCoordinateMapper.map(point, screen: screenGuard.context.screen, rotation: rotation)
        try backend.checkInputAvailability(budget: budget)
        _ = try hid.tap(mapped, onContact: onInputStarted) { try self.backend.checkInputCanContinue() }
        focusTapQueued = true
        let focused = try textFocusFrame(budget: budget)
        guard editor.sameEditor(as: NativeTextResponder(focused)) else {
            throw focusFailure("Focus was not confirmed after tapping the requested editor", focused)
        }
    }

    func confirmTextFocus(stage: String, budget: NativeCaptureBudget) throws -> [String: Any] {
        let frame = try textFocusFrame(budget: budget)
        captures += 1
        let confirmed = target.textEditor?.sameEditor(as: NativeTextResponder(frame)) == true
        let facts: [String: Any] = ["stage": stage, "sameTextResponderConfirmed": confirmed,
                                    "validation": "foreground_text_responder"]
        preInputChecks.append(facts)
        guard confirmed else { throw focusFailure("The original editor no longer has confirmed keyboard focus", frame) }
        return facts
    }

    private func textFocusFrame(budget: NativeCaptureBudget, hit point: CGPoint? = nil) throws -> CapturedObservation {
        try backend.checkInputAvailability(budget: budget)
        let frame = try backend.keyboardFocusFrame(budget: budget, hit: point)
        guard let display = target.context["displayID"] as? UInt64, frame.metadata["displayID"] as? UInt64 == display,
            frame.metadata["displayUniqueID"] as? String == target.context["displayUniqueID"] as? String,
            frame.metadata["captureSource"] as? String == target.context["captureSource"] as? String,
            frame.metadata["orientationResynchronized"] as? Bool != true,
            frame.metadata["displayRotation"] as? String == rotation,
            frame.metadata["nativeRotation"] as? String == "rot0",
            let raw = frame.metadata["screenContext"] as? [String: Any],
            screenGuard.context.matches(try JSONDecoder().decode(ScreenContext.self, from: jsonData(raw))) else {
            throw focusFailure("Display context changed before text input", frame)
        }
        try budget.check()
        return frame
    }

    private func focusFailure(_ message: String, _ frame: CapturedObservation? = nil) -> ActionFailure {
        ActionFailure(code: "native_keyboard_focus_unverified", description: message, possiblyExecuted: false,
                      requiresObservation: true, rejectedCapture: frame)
    }
}
