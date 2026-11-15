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
    func observeAfterAction(
        textOptions: NativeTextObservationOptions?, ignoring: ScreenRect?, sourceContext: ScreenContext?
    ) throws -> CapturedObservation {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        let captured = try NativePostActionStability.capture(
            ignoring: ignoring, sourceContext: sourceContext,
            checkCancellation: { try self.cancellation.check() },
            sample: { deadline in
                // All samples and owned recovery share one bounded post-action
                // deadline. No sampling can extend the original input lease.
                try self.capture(
                    textOptions: textOptions,
                    budget: NativeCaptureBudget(requestDeadline: deadline, purpose: .observation))
            })
        return try captureAXP(previous: captured, textOptions: textOptions, deadline: deadline)
    }

    private func observeTextOrScreen(_ textOptions: NativeTextObservationOptions?) throws -> CapturedObservation {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        return try captureAXP(textOptions: textOptions, deadline: deadline)
    }

    private func captureAXP(
        previous: CapturedObservation? = nil,
        textOptions: NativeTextObservationOptions?, deadline: TimeInterval
    ) throws -> CapturedObservation {
        guard let cli else { throw IPhoneUseError("backend_unavailable", "Native backend not started") }
        let reader = axpReader, cancellation = cancellation
        return try AXPObservation.capture(
            device: cli.device, generation: generation, previous: previous,
            read: { cancelled in
                guard let reader else {
                    throw IPhoneUseError("axp_runtime_unavailable", "Native AXP reader unavailable; use the screenshot")
                }
                return try reader.read(device: cli.device, cancelled: {
                    cancelled() || cancellation.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline
                })
            }, screenshot: {
                if previous == nil, textOptions == nil, cli.nativeScreenshot != nil {
                    let attempt = AppleCaptureAttempt(cli: cli, generation: self.generation,
                        budget: NativeCaptureBudget(requestDeadline: deadline, purpose: .observation))
                    do { return try attempt.nativeObservation() } catch let error as IPhoneUseError
                        where AppleCaptureAttempt.needsDisplaySelection(error) { }
                }
                return try self.capture(
                    textOptions: textOptions,
                    budget: NativeCaptureBudget(requestDeadline: deadline, purpose: .observation))
            }, checkCancellation: { try self.cancellation.check() })
    }
    func capture(textOptions: NativeTextObservationOptions? = nil, budget: NativeCaptureBudget? = nil) throws
        -> CapturedObservation {
        try captureOnce(textOptions: textOptions, budget: budget)
    }
    private func captureOnce(
        textOptions: NativeTextObservationOptions?, budget: NativeCaptureBudget?
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
        return CapturedObservation(nodes: captured.nodes, metadata: metadata, screenshot: captured.screenshot)
    }
}
