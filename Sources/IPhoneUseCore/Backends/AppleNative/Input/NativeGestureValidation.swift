import IPhoneUseRunnerSupport

// Selected only by the native coordinate-input caller, after validating the complete gesture.
// Preserve actual pixel measurements; change which measurements can reject this action.
struct NativeGestureValidation {
    private let diagnosticGlobal: Bool
    private let diagnosticRegions: [Int]

    init(action: DeviceAction, gesture: CoordinateGesture) throws {
        guard action.coordinate,
              ["tap", "double-tap", "long-press", "pinch", "swipe"].contains(action.kind) else {
            throw ScreenGuard.Failure.invalidGuard
        }
        try gesture.validate(kind: action.kind)
        diagnosticGlobal = !action.explicitGlobalGuard
        // Region 0 is the touch-down neighborhood. Region 1 is the swipe corridor.
        // Keep touch-down, explicit context regions and all pinch regions protected.
        diagnosticRegions = action.kind == "swipe" ? [1] : []
    }

    func apply(to check: inout ScreenGuard.Check) {
        guard check.dynamicMatches == nil else { return }
        check.diagnosticOnlyGlobal = diagnosticGlobal
        check.diagnosticOnlyRegions = diagnosticRegions
    }
}
