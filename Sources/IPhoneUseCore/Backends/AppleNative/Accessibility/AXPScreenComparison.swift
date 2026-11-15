import Foundation
import IPhoneUseRunnerSupport

// Pixel differences are evidence, not an AX association veto or action authority.
struct AXPScreenComparison {
    let equivalent: Bool
    let contextCompatible: Bool
    let result: [String: Any]

    init(_ first: CapturedObservation, _ second: CapturedObservation) throws {
        let contextKeys = ["deviceID", "sessionGeneration", "displayID", "displayUniqueID",
                           "displayRotation", "screenFrame"]
        let differences = contextKeys.filter { key in
            guard let left = first.metadata[key], let right = second.metadata[key] else { return true }
            return !NSDictionary(dictionary: [key: left]).isEqual(to: [key: right])
        }
        let keys = contextKeys + ["captureStartedAt", "captureCompletedAt", "screenshotCapturedAt",
                                  "captureStartedUptime", "frameHash", "screenshotWidth", "screenshotHeight"]
        var details: [String: Any] = [
            "version": 1, "algorithm": FrameComparison.algorithm,
            "before": first.metadata.filter { keys.contains($0.key) },
            "after": second.metadata.filter { keys.contains($0.key) },
            "contextMismatchKeys": differences,
            "beforeMissingContextKeys": contextKeys.filter { first.metadata[$0] == nil },
            "afterMissingContextKeys": contextKeys.filter { second.metadata[$0] == nil }
        ]
        // Preserve image validation and the context-mismatch short circuit.
        if differences.isEmpty {
            let reference = try FrameFingerprint(png: first.screenshot)
            let current = try FrameFingerprint(png: second.screenshot)
            let comparison = FrameComparison(reference: reference, current: current)
            equivalent = comparison.equivalent
            contextCompatible = comparison.dimensionsMatch
            details["pixelComparison"] = comparison.result
            details["referenceHash"] = reference.hash
            details["currentHash"] = current.hash
            details["reason"] = equivalent ? "equivalent" : "pixels_differ"
            details["pixelComparisonPerformed"] = true
        } else {
            equivalent = false
            contextCompatible = false
            details["reason"] = "context_mismatch"
            details["pixelComparisonPerformed"] = false
        }
        details["equivalent"] = equivalent
        details["contextCompatible"] = contextCompatible
        details["pixelPolicy"] = "diagnostic_only"
        result = details
    }
}
