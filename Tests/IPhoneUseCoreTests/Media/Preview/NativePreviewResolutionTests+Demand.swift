import XCTest
import CoreImage
@testable import IPhoneUseCore

extension NativePreviewResolutionTests {
    func testDemandCapsAtActualSourcePixelsIncludingReducedActiveRectangle() throws {
        let context = CIContext(options: [.useSoftwareRenderer: true])
        for reduced in [false, true] {
            let buffer = try pixels(activeWidth: reduced ? 32 : 64, activeHeight: reduced ? 64 : 128)
            let frame = NativeVideoSnapshot.Frame(image: .init(
                pixels: buffer, nativeWidth: 48, nativeHeight: 96,
                activeWidth: reduced ? 32 : 64, activeHeight: reduced ? 64 : 128
            ), firstPacketAt: 1, completedAt: 2, timestamp: 1)
            for rotation in ["rot0", "rot90", "rot180", "rot270"] {
                for edge in [24, 72, 4096] {
                    let jpeg = try NativePreview.encodeJPEG(
                        frame, display: display(rotation), context: context, longEdge: edge)
                    let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg.data as CFData, nil))
                    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                    let long = min(edge, reduced ? 48 : 96)
                    XCTAssertEqual(image.width, ["rot0", "rot180"].contains(rotation) ? long / 2 : long)
                    XCTAssertEqual(image.height, ["rot0", "rot180"].contains(rotation) ? long : long / 2)
                }
            }
        }
    }
}
