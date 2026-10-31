import Foundation

// Presentation only. Never use a frame tag to authorize a screenshot or input.
// The physical display/crop still comes from CoreDevice; only the view rotates.
enum NativePreviewGeometry {
    static func sameSurface(_ first: NativeDisplay, _ second: NativeDisplay) -> Bool {
        first.id == second.id && first.uniqueID == second.uniqueID && first.scale == second.scale
            && first.nativeRotation == second.nativeRotation
            && nativeSize(first) == nativeSize(second)
    }

    private static func nativeSize(_ display: NativeDisplay) -> [Double] {
        ["rot90", "rot270"].contains(display.rotation)
            ? [display.pixelHeight, display.pixelWidth] : [display.pixelWidth, display.pixelHeight]
    }

    static func display(for frame: NativeVideoSnapshot.Frame, bound: NativeDisplay) throws -> NativeDisplay {
        guard let rotation = frame.displayRotation else {
            // Unknown RTP profiles retain the existing metadata/recovery path.
            return bound
        }
        let oriented = try NativeDisplay([
            "backlightState": bound.backlightOn ? "activeOn" : "inactive",
            "displays": [[
                "primary": true, "displayId": bound.id, "bounds": [[0, 0], nativeSize(bound)],
                "uniqueId": bound.uniqueID as Any? ?? NSNull(),
                "pointScale": bound.scale, "nativeOrientation": bound.nativeRotation,
                "currentOrientation": rotation
            ]]
        ])
        _ = try NativeSnapshotImage.validateGeometry(frame, display: oriented,
            allowReducedResolution: true, allowScaledCanvas: true)
        return oriented
    }

    // Re-read direction after a successful bind: a fold and a rotation may
    // settle on different polls. This never changes the media surface or input
    // geometry; validate decoded pixels against the fresh CoreDevice candidate.
    static func revalidatedDisplay(
        frame: NativeVideoSnapshot.Frame?, bound: NativeDisplay, current: NativeDisplay
    ) throws -> NativeDisplay {
        guard sameSurface(bound, current) else {
            throw IPhoneUseError("preview_geometry_conflict", "Preview surface changed during validation")
        }
        do {
            _ = try NativeSnapshotImage.validateGeometry(
                frame, display: current, allowReducedResolution: true, allowScaledCanvas: true)
        } catch {
            throw IPhoneUseError("preview_geometry_conflict", "Preview frame and display have not settled: \(error)")
        }
        return current
    }

    static func continuousDisplay(
        frame: NativeVideoSnapshot.Frame?, bound: NativeDisplay, current: NativeDisplay
    ) -> NativeDisplay? {
        guard sameSurface(bound, current), let frame, frame.displayRotation != nil else { return nil }
        return try? display(for: frame, bound: current)
    }
}
