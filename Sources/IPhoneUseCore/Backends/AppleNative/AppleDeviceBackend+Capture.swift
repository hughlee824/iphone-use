import IPhoneUseRunnerSupport
import Foundation
import CoreGraphics
import ImageIO
import AppleNativeBridge

extension AppleDeviceBackend {
    func observe() throws -> CapturedObservation {
        try observeTextOrScreen(nil)
    }
    func observeText(_ options: NativeTextObservationOptions) throws -> CapturedObservation {
        try observeTextOrScreen(options)
    }
    func observeAfterTextEdit(_ options: NativeTextObservationOptions?) throws -> CapturedObservation {
        let started = ProcessInfo.processInfo.systemUptime
        let diagnostics = NativePostActionDiagnostics.fromEnvironment()
        do {
            let frame = try captureAXP(textOptions: options, deadline: started + 30, axFirst: true)
            diagnostics?.record(frame, phase: "finalObservation", started: started)
            return diagnostics?.complete(frame) ?? frame
        } catch {
            diagnostics?.record(error, started: started, phase: "finalObservation")
            diagnostics?.fail(error)
            throw error
        }
    }
    func observeAfterAction(
        actionKind: String?,
        textOptions: NativeTextObservationOptions?, ignoring: ScreenRect?, sourceContext: ScreenContext?
    ) throws -> CapturedObservation {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        let diagnostics = NativePostActionDiagnostics.fromEnvironment()
        let adjacentTap = actionKind == "tap"
        let tapDisplay = NativeTapFrameWorker.DisplayHistory()
        do {
            let captured = try NativePostActionStability.capture(
                policy: adjacentTap ? .adjacentTap : .conventional,
                ignoring: ignoring, sourceContext: sourceContext, checkCancellation: { try self.cancellation.check() },
                sample: { cutoff in
                    if adjacentTap {
                        return try tapDisplay.sample { noteDisplay in
                            try self.stabilitySample(until: deadline, startBefore: cutoff, noteDisplay: noteDisplay,
                                textOptions: textOptions, diagnostics: diagnostics)
                        }
                    }
                    return try self.stabilitySample(until: cutoff, startBefore: nil, noteDisplay: nil,
                        textOptions: textOptions, diagnostics: diagnostics)
                })
            diagnostics?.stability = captured.metadata["postActionStability"]
            if adjacentTap {
                let result = try captureAXP(selected: captured, textOptions: textOptions, deadline: deadline)
                return diagnostics?.complete(result) ?? result
            }
            let started = ProcessInfo.processInfo.systemUptime
            let result = try captureAXP(previous: captured, textOptions: textOptions, deadline: deadline)
            diagnostics?.record(result, phase: "finalObservation", started: started)
            return diagnostics?.complete(result) ?? result
        } catch {
            diagnostics?.fail(error)
            throw error
        }
    }

    private func stabilitySample(
        until deadline: TimeInterval, startBefore: TimeInterval?, noteDisplay: ((NativeDisplay) -> Void)?,
        textOptions: NativeTextObservationOptions?, diagnostics: NativePostActionDiagnostics?
    ) throws -> CapturedObservation {
        let started = ProcessInfo.processInfo.systemUptime
        let capture = {
            try self.capture(textOptions: textOptions,
                budget: NativeCaptureBudget(requestDeadline: deadline, purpose: .observation,
                    screenshotStartDeadline: startBefore, noteDisplay: noteDisplay))
        }
        do {
            let frame = try startBefore == nil ? capture() : tapFrames.run(capture)
            diagnostics?.record(frame, phase: "stability", started: started)
            return frame
        } catch {
            diagnostics?.record(error, started: started)
            throw error
        }
    }

    private func observeTextOrScreen(_ textOptions: NativeTextObservationOptions?) throws -> CapturedObservation {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        return try captureAXP(textOptions: textOptions, deadline: deadline)
    }

    func keyboardFocusFrame(budget: NativeCaptureBudget, hit point: CGPoint? = nil) throws -> CapturedObservation {
        let image = try capture(budget: budget)
        let frame = try captureAXP(selected: image, textOptions: nil, deadline: budget.deadline, hit: point)
        try budget.check()
        return frame
    }

    private func captureAXP(
        previous: CapturedObservation? = nil, selected: CapturedObservation? = nil,
        textOptions: NativeTextObservationOptions?, deadline: TimeInterval, hit point: CGPoint? = nil,
        axFirst: Bool = false
    ) throws -> CapturedObservation {
        guard let cli else { throw IPhoneUseError("backend_unavailable", "Native backend not started") }
        let reader = axpReader, cancellation = cancellation
        func read(_ cancelled: () -> Bool) throws -> [String: Any] {
            guard let reader else {
                throw IPhoneUseError("axp_runtime_unavailable", "Native AXP reader unavailable; use the screenshot")
            }
            return try reader.read(device: cli.device, focusPoint: point, cancelled: {
                cancelled() || cancellation.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline
            })
        }
        if let selected {
            return try AXPObservation.captureSelected(selected, device: cli.device, generation: generation,
                read: { try read { false } }, checkCancellation: { try cancellation.check() })
        }
        return try AXPObservation.capture(
            device: cli.device, generation: generation, previous: previous, axFirst: axFirst, read: read, screenshot: {
                return try self.capture(
                    textOptions: textOptions,
                    budget: NativeCaptureBudget(requestDeadline: deadline, purpose: .observation))
            }, checkCancellation: { try self.cancellation.check() })
    }
    func capture(
        textOptions: NativeTextObservationOptions? = nil, budget: NativeCaptureBudget? = nil
    ) throws -> CapturedObservation {
        guard let cli else { throw IPhoneUseError("backend_unavailable", "Native backend not started") }
        let captured = try cli.capture(
            generation: generation, budget: budget,
            prepareDisplay: { _ in try self.cancellation.check() },
            validateDisplay: { _, _ in ["verification": "apple_png_and_stable_display_metadata"] })
        var metadata = captured.metadata
        if let textOptions {
            guard let rawContext = captured.metadata["screenContext"] as? [String: Any] else {
                throw ScreenGuard.Failure.invalidGuard
            }
            let context = try JSONDecoder().decode(ScreenContext.self, from: jsonData(rawContext))
            _ = try ScreenGuard(
                png: captured.screenshot, context: context,
                rects: [textOptions.field], policy: .init(), ignoring: textOptions.ignoring)
            metadata["textObservationOptions"] = try textOptions.result
        }
        return CapturedObservation(nodes: captured.nodes, metadata: metadata, screenshot: captured.screenshot,
            validatedPixels: captured.validatedPixels)
    }
}
