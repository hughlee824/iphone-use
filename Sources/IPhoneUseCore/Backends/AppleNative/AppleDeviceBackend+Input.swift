import Foundation
import CoreGraphics
import ImageIO
import AppleNativeBridge

extension AppleDeviceBackend {
    func perform(_ action: DeviceAction, target: ObservedTarget, onInputStarted: @escaping () -> Void) throws
        -> [String: Any] {
        let typing = action.kind == "type" && action.reference.node == nil
        let pressing = action.kind == "press" && action.reference.node == nil
        let keyboardAction = typing || pressing
        let homeAction = action.kind == "home"
        guard
            keyboardAction || homeAction
                || (["tap", "double-tap", "long-press", "pinch", "swipe"].contains(action.kind)
                    && action.coordinate)
        else {
            throw IPhoneUseError(
                "native_action_unsupported",
                """
                Use coordinate tap/double-tap/long-press/pinch/swipe, home oN, or type/press oN after visually\
                 confirming focus
                """
            )
        }
        let textInput =
            typing
            ? try NativeTextInput(
                text: validatedValue(action.fields["text"], as: String.self),
                mode: validatedValue(action.fields["mode"], as: String.self),
                method: action.fields["textMethod"] as? String ?? "auto") : nil
        defer { if textInput?.usesPasteboard == true { pasteboard?.endInputAttempt() } }
        return try AppleInputAttempt(backend: self, action: action, target: target, textInput: textInput)
            .run(onInputStarted: onInputStarted)
    }
    func prepareText() throws -> [String: Any] { try prepareText(registerRSDKeyboard: false) }

    func prepareText(registerRSDKeyboard: Bool) throws -> [String: Any] {
        try cancellation.check()
        let control = controlStatus()
        guard control.available, let hid else {
            throw ActionFailure(
                code: "native_control_unavailable",
                description: control.message ?? "Native control is unavailable",
                possiblyExecuted: false, requiresObservation: false, result: control.result)
        }
        let alreadyPrepared = hid.keyboardStatus["prepared"] as? Bool == true
        if registerRSDKeyboard && hid.registeredKeyboard == nil {
            guard !alreadyPrepared, let cli, let identifier = coreDeviceIdentifier, let ownership = deviceLock else {
                throw IPhoneUseError(
                    "native_keyboard_route_conflict", "Select RSD keyboard before preparing any keyboard")
            }
            hid.registeredKeyboard = RegisteredKeyboard { [weak self] in
                guard let self else { throw IPhoneUseError("native_session_closing", "Keyboard session closed") }
                let display = try NativeDisplay(cli.read(["device", "info", "displays"]))
                let tunnel = try KeyboardTunnel(
                    device: cli.device, identifier: identifier, display: display.id, ownership: ownership)
                self.keyboardTunnel = tunnel
                return try tunnel.open(pasteboard: false)
            }
        }
        do { try hid.prepareKeyboard() } catch {
            if !alreadyPrepared, hid.registeredKeyboard != nil { keyboardTunnel?.close() }
            throw ActionFailure(
                code: (error as? ActionFailure)?.code ?? (error as? IPhoneUseError)?.code
                    ?? "native_keyboard_unavailable",
                description: String(describing: error),
                possiblyExecuted: hid.registeredKeyboard?.registrationMayExist == true,
                requiresObservation: true,
                result: [
                    "keyboardPrepared": false, "keyboard": hid.keyboardStatus,
                    "inputReportsSent": 0, "clipboardAccessed": false,
                    "recovery": NativeRecovery.resolveError.result
                ])
        }
        return [
            "keyboardPrepared": true, "alreadyPrepared": alreadyPrepared, "keyboard": hid.keyboardStatus,
            "inputReportsSent": 0, "focusConfirmed": false, "clipboardAccessed": false
        ]
    }
    func finishText(transaction: String, observation: [String: Any]) throws -> [String: Any] {
        try cancellation.check()
        let now = ProcessInfo.processInfo.systemUptime
        // SessionHost requires the current observation; the transaction requires a
        // post-attempt capture. Reviewing that result need not finish in 30 seconds.
        // Restoration still checks live clipboard ownership, without sending input.
        guard observation["deviceID"] as? String == cli?.device,
            observation["sessionGeneration"] as? String == generation,
            let captured = observation["captureStartedUptime"] as? Double,
            captured.isFinite, captured >= 0, captured <= now
        else {
            throw IPhoneUseError(
                "stale_reference", "Observe this device/session again before confirming text completion")
        }
        guard let pasteboard else {
            throw IPhoneUseError(
                "no_text_transaction", "No clipboard text transaction exists in this session")
        }
        return try pasteboard.finish(transaction: transaction, observedAt: captured)
    }
}
