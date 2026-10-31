import Foundation

extension AppleDeviceBackend {
    func controlStatus() -> NativeControlStatus {
        NativeControlStatus.resolve(
            hid: hid?.state, media: [:], closing: cancellation.isCancelled,
            startupCode: controlErrorCode, startupError: controlError, requiresMedia: false)
    }
    func checkInputAvailability(budget: NativeCaptureBudget? = nil) throws {
        try cancellation.check()
        try budget?.check()
        // Input independently checks fresh Apple screenshots, display identity,
        // lock state and screen guards. Media health never grants input readiness.
    }
    func checkInputCanContinue() throws { try cancellation.check() }
}
