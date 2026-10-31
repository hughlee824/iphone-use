import Foundation
import AppleNativeBridge

// Raw XCTest screenshot axes plus EXIF orientation. Only conflict evidence:
// CoreDevice remains the authority after stopping the owned stream.
struct RunnerPreviewGeometry {
    let width: Int, height: Int, orientation: Int

    func conflicts(with display: NativeDisplay) -> Bool {
        let sideways = orientation == 6 || orientation == 8
        // XCTest rounds odd display dimensions down to even image dimensions.
        // This is negative preview evidence, never input geometry authority.
        func matches(_ actual: Int, _ expected: Int) -> Bool {
            actual == expected || (expected % 2 == 1 && actual == expected - 1)
        }
        if !matches(sideways ? height : width, Int(display.pixelWidth))
            || !matches(sideways ? width : height, Int(display.pixelHeight)) {
            return true
        }
        let displaySideways = display.rotation == "rot90" || display.rotation == "rot270"
        let nativeWidth = Int(displaySideways ? display.pixelHeight : display.pixelWidth)
        let nativeHeight = Int(displaySideways ? display.pixelWidth : display.pixelHeight)
        // An upright EXIF tag describes storage, not device posture. In
        // particular it cannot distinguish portrait from upside-down portrait.
        // Keep size checks, but only explicit non-upright tags supply direction.
        guard orientation != 1, display.nativeRotation == "rot0",
            matches(width, nativeWidth), matches(height, nativeHeight) else {
            return false
        }
        return [1: "rot0", 3: "rot180", 6: "rot90", 8: "rot270"][orientation] != display.rotation
    }
}

protocol RunnerRecordingConnection: AnyObject {
    var source: NativeRecordingSource { get }
    var sessionID: String { get }
    var rotation: String { get }
    func verifyDisplay() throws
    var previewReceiver: NativeRTPReceiver? { get }
    var previewDisplay: NativeDisplay? { get }
    var previewDevice: NativePreviewDevice { get }
    var previewRefreshReason: String { get }
    func previewNeedsRefresh() throws -> Bool
    func refreshPreview() throws
    func preparePreviewValidation() throws
    func previewCanResumeAfterUnlock() throws -> Bool
    func close() -> [String: Any]
}

extension RunnerRecordingConnection {
    var previewRefreshReason: String { "display_changed" }
    var previewReceiver: NativeRTPReceiver? { nil }
    var previewDisplay: NativeDisplay? { nil }
    var previewDevice: NativePreviewDevice { .unknown }
    func previewNeedsRefresh() throws -> Bool { try verifyDisplay(); return false }
    func refreshPreview() throws { try verifyDisplay() }
    func preparePreviewValidation() throws {}
    func previewCanResumeAfterUnlock() throws -> Bool { try verifyDisplay(); return true }
    func synchronizeRecordingOrientation() throws -> Bool {
        guard let frameRotation = previewReceiver?.snapshots?.previewFrame()?.displayRotation,
            frameRotation != rotation else { return false }
        try refreshPreview()
        return true
    }
}
