import Foundation
import VideoToolbox
import CoreImage

enum NativeSnapshotImage {
    static func validateGeometry(
        _ frame: NativeVideoSnapshot.Frame?, display: NativeDisplay, allowReducedResolution: Bool = false,
        allowScaledCanvas: Bool = false
    ) throws -> (width: Int, height: Int) {
        guard let frame else {
            throw IPhoneUseError(
                "native_snapshot_freshness_unavailable",
                "No fresh complete media frame to verify display geometry")
        }
        guard display.nativeRotation == "rot0",
            NativeVideoOrientation(rawValue: display.rotation) != nil
                || (allowScaledCanvas && display.rotation == "rot180")
        else {
            throw IPhoneUseError("native_snapshot_geometry_unavailable", "Unverified media orientation")
        }
        // Independent per-frame negative evidence. CoreDevice metadata and PNG
        // can retain the same stale half-turn while this owned stream is alive.
        // Never use the tag itself as an observation/input coordinate transform.
        if let rotation = frame.displayRotation, rotation != display.rotation {
            throw IPhoneUseError(
                "native_snapshot_geometry_unavailable",
                "RTP frame orientation conflicts with the bound display")
        }
        let sideways = ["rot90", "rot270"].contains(display.rotation)
        let width = Int(sideways ? display.pixelHeight : display.pixelWidth)
        let height = Int(sideways ? display.pixelWidth : display.pixelHeight)
        if allowScaledCanvas, frame.image.nativeWidth < width, frame.image.nativeHeight < height {
            // Some displays negotiate a smaller HEVC canvas, independently of
            // VRA's active rectangle. Preview may use its proportional pixels;
            // native observation validation retains exact display geometry.
            let image = frame.image
            let expectedHeight = Double(height) * Double(image.nativeWidth) / Double(width)
            guard abs(Double(image.nativeHeight) - expectedHeight) <= 1 else {
                throw IPhoneUseError("native_snapshot_geometry_unavailable", "Preview aspect ratio changed")
            }
            try validateNativeRectangle(
                image, width: image.nativeWidth, height: image.nativeHeight, allowReducedResolution: true)
            return (image.nativeWidth, image.nativeHeight)
        }
        try validateNativeRectangle(
            frame.image, width: width, height: height, allowReducedResolution: allowReducedResolution)
        return (width, height)
    }

    static func validateNativeRectangle(
        _ image: NativeDecodedVideoFrame, width: Int, height: Int, allowReducedResolution: Bool = false
    ) throws {
        let pixels = image.pixels
        let encodedWidth = CVPixelBufferGetWidth(pixels), encodedHeight = CVPixelBufferGetHeight(pixels)
        // DisplayService rounds the iPhone 16 Pro's 2622-row native image to
        // 2624 rows in its frame metadata. Accept only that four-row alignment;
        // Apple display geometry remains the crop and coordinate authority.
        let nativeHeightMatches =
            image.nativeHeight == height || (height % 4 == 2 && image.nativeHeight == height + 2)
        guard !image.isReducedResolution || allowReducedResolution,
            image.activeWidth > 0, image.activeHeight > 0,
            image.activeWidth <= encodedWidth, image.activeHeight <= encodedHeight,
            image.nativeWidth <= encodedWidth, image.nativeHeight <= encodedHeight,
            !image.isReducedResolution || (image.activeWidth % 16 == 0 && image.activeHeight % 16 == 0),
            image.nativeWidth == width, nativeHeightMatches,
            width > 0, height > 0, encodedWidth >= width, encodedHeight >= height, encodedWidth - width < 64,
            encodedHeight - height < 64,
            [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange].contains(
                CVPixelBufferGetPixelFormatType(pixels))
        else {
            throw IPhoneUseError(
                "native_snapshot_geometry_unavailable",
                """
                Media dimensions do not match native screen axes (native\
                 \(image.nativeWidth)x\(image.nativeHeight), expected \(width)x\(height), encoded\
                 \(encodedWidth)x\(encodedHeight), active \(image.activeWidth)x\(image.activeHeight))
                """
            )
        }
    }

}
