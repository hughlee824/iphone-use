import Foundation
import IPhoneUseRunnerSupport

// A responder token is meaningful only within the same AX reader lease and foreground application.
struct NativeTextResponder: Equatable {
    let lease: String
    let bundle: String
    let pid: Int
    let objectID: String
    let role: String
    let field: ScreenRect

    init?(_ capture: CapturedObservation) {
        let metadata = capture.metadata
        guard metadata["axStatus"] as? String == "available", metadata["sourceTruncated"] as? Bool != true,
            let cleanup = metadata["axCleanup"] as? [String: Any],
            let connection = cleanup["connectionLease"] as? [String: Any],
            let lease = connection["generation"] as? String, UUID(uuidString: lease) != nil,
            let bundle = metadata["axApplicationBundleId"] as? String, !bundle.isEmpty else { return nil }
        let matches = capture.nodes.filter { $0.attributes["keyboardFocus"] as? Bool == true }
        guard matches.count == 1, let node = matches.first,
            ["text_field", "search_field", "text_view"].contains(node.role),
            let element = node.attributes["nativeElement"] as? [String: Any],
            let pid = element["pid"] as? Int, pid > 0, let objectID = element["objectID"] as? String,
            let number = UInt64(objectID), number > 0, let field = Self.rect(node) else { return nil }
        self.lease = lease; self.bundle = bundle; self.pid = pid
        self.objectID = objectID; role = node.role; self.field = ScreenRect(field)
    }

    static func rect(_ node: AXNode) -> CGRect? {
        (node.attributes["frame"] as? [String: Any]).flatMap(AXPSnapshot.rect)
    }
}

struct NativeKeyboardAttachment {
    let responder: NativeTextResponder
    let fieldGuard: NativeTextFieldGuard
    private let aboveKeyboard: ScreenGuard?

    init?(source: CapturedObservation, field: ScreenRect?, guard original: ScreenGuard,
          fieldGuard: NativeTextFieldGuard?) throws {
        guard let responder = NativeTextResponder(source),
            original.context.screen.cgRect.contains(responder.field.cgRect) else { return nil }
        // CLI rectangles can be rounded outward to whole screen points.
        if let field {
            let observed = responder.field.cgRect, supplied = field.cgRect
            guard supplied.contains(observed), supplied.width - observed.width < 2,
                supplied.height - observed.height < 2 else { return nil }
        }
        self.responder = responder
        if let field, let fieldGuard, field == original.regions.first?.rect {
            self.fieldGuard = fieldGuard
        } else {
            self.fieldGuard = try NativeTextFieldGuard(png: source.screenshot, context: original.context,
                                                      field: responder.field)
        }
        let screen = original.context.screen.cgRect
        if let keyboard = Self.dockedKeyboard(in: source, screen: screen),
            responder.field.cgRect.maxY <= keyboard.minY, original.ignoredRect == nil {
            let upper = CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: keyboard.minY - screen.minY)
            aboveKeyboard = try ScreenGuard(png: source.screenshot, context: original.context,
                                            rects: [ScreenRect(upper)], policy: original.policy)
        } else { aboveKeyboard = nil }
    }

    func confirm(_ frame: CapturedObservation) throws {
        guard NativeTextResponder(frame) == responder else {
            throw ActionFailure(code: "native_keyboard_focus_unverified",
                                description: "Keyboard attachment requires the same focused text field",
                                possiblyExecuted: false, requiresObservation: true, rejectedCapture: frame)
        }
    }

    // Read-only samples share the first preflight deadline. AX may already report the
    // keyboard hidden while the paired screenshot still shows the dismissal animation.
    func settledFrame(original: ScreenGuard, capture: () throws -> CapturedObservation) throws -> CapturedObservation {
        var frame = try capture()
        try confirm(frame)
        guard aboveKeyboard != nil else { return frame }
        for _ in 0..<3 {
            let previous = try ScreenGuard(png: frame.screenshot, context: original.context,
                                           rects: [original.context.screen], policy: original.policy)
            frame = try capture()
            try confirm(frame)
            if try previous.check(image: ScreenImage(png: frame.screenshot), context: original.context).globalAccepted {
                return frame
            }
        }
        throw ActionFailure(code: "screen_changed", description: "Keyboard attachment did not settle before input",
                            possiblyExecuted: false, requiresObservation: true, rejectedCapture: frame)
    }

    func afterRegistration(_ frame: CapturedObservation, original: ScreenGuard) throws -> ScreenGuard {
        // Permit only the disappearance of a previously observed docked software keyboard.
        // The caller still compares the original field pixels, device, display, source and orientation.
        guard let aboveKeyboard, let raw = frame.metadata["screenContext"] as? [String: Any] else { return original }
        let context = try JSONDecoder().decode(ScreenContext.self, from: jsonData(raw))
        guard original.context.matches(context), !frame.nodes.contains(where: {
            $0.role == "keyboard" && (NativeTextResponder.rect($0)?.intersects(context.screen.cgRect) ?? true)
        }) else { return original }
        let image = try ScreenImage(png: frame.screenshot)
        let upper = try aboveKeyboard.check(image: image, context: context)
        guard upper.regionChanges.count == 1, upper.regionChanges[0] <= original.policy.maxScreenChange else {
            return original
        }
        return try ScreenGuard(png: frame.screenshot, context: context, rects: original.regions.map(\.rect),
                               policy: original.policy)
    }

    private static func dockedKeyboard(in source: CapturedObservation, screen: CGRect) -> CGRect? {
        let keyboards = source.nodes.filter { $0.role == "keyboard" }
        guard keyboards.count == 1, let node = keyboards.first, let keys = NativeTextResponder.rect(node),
            screen.contains(keys) else { return nil }
        var parent = node.parent
        while let index = parent, index >= 0, index < node.index, index < source.nodes.count {
            let ancestor = source.nodes[index]
            if let attrs = ancestor.attributes["nativeAttributes"] as? [String: Any],
                attrs["5003"] as? String == "UIInputSetHostView", let host = NativeTextResponder.rect(ancestor),
                host.minX == screen.minX, host.width == screen.width, host.maxY == screen.maxY,
                host.minY >= screen.midY, host.contains(keys) { return host }
            guard let next = ancestor.parent, next < index else { return nil }
            parent = next
        }
        return nil
    }
}

extension AppleInputAttempt {
    func prepareKeyboardForInput() throws {
        try screenGuard.validate()
        guard screenGuard.regions.map(\.rect) == [action.textRegion ?? screenGuard.context.screen] else {
            throw ScreenGuard.Failure.invalidGuard
        }
        // Reuse the selected keyboard, then validate the current field before any key.
        let firstType = textInput != nil && hid.registeredKeyboard != nil && !hid.keyboardReady
        _ = try backend.prepareText()
        if firstType {
            guard let source = target.textSource,
                let binding = try NativeKeyboardAttachment(source: source, field: action.textRegion,
                                                           guard: screenGuard, fieldGuard: target.textFieldGuard)
            else {
                throw ActionFailure(code: "native_keyboard_focus_unverified",
                                    description: "Inspect the focused field after keyboard registration",
                                    possiblyExecuted: false, requiresObservation: true)
            }
            attachment = binding
        }
    }

    func attachmentFrame(stage: String, budget: NativeCaptureBudget) throws -> CapturedObservation? {
        guard let attachment else { return nil }
        let capture = { try self.backend.keyboardFocusFrame(budget: budget) }
        if stage == "after_clipboard" {
            let frame = try capture()
            try attachment.confirm(frame)
            return frame
        }
        let frame = try attachment.settledFrame(original: screenGuard, capture: capture)
        screenGuard = try attachment.afterRegistration(frame, original: screenGuard)
        return frame
    }
}
