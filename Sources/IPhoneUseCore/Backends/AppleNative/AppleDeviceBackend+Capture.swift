import IPhoneUseRunnerSupport
import Foundation
import CoreGraphics
import ImageIO
import AppleNativeBridge

extension AppleDeviceBackend {
    func observe() throws -> CapturedObservation {
        try capture(
            budget: NativeCaptureBudget(
                requestDeadline: ProcessInfo.processInfo.systemUptime + 30, purpose: .observation))
    }
    func observeText(_ options: NativeTextObservationOptions) throws -> CapturedObservation {
        try capture(
            textOptions: options,
            budget: NativeCaptureBudget(
                requestDeadline: ProcessInfo.processInfo.systemUptime + 30, purpose: .observation))
    }
    func observeAfterAction(
        textOptions: NativeTextObservationOptions?, ignoring: ScreenRect?, sourceContext: ScreenContext?
    ) throws -> CapturedObservation {
        try NativePostActionStability.capture(
            ignoring: ignoring, sourceContext: sourceContext,
            checkCancellation: { try self.cancellation.check() },
            sample: { deadline in
                // All samples and owned recovery share one bounded post-action
                // deadline. No sampling can extend the original input lease.
                try self.capture(
                    textOptions: textOptions,
                    budget: NativeCaptureBudget(requestDeadline: deadline, purpose: .observation))
            })
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
