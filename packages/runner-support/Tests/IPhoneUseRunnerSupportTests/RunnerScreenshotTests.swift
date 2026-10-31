import XCTest
import CoreGraphics
import ImageIO
@testable import IPhoneUseRunnerSupport

final class RunnerScreenshotTests: XCTestCase {
    func testUntaggedUpsideDownPixelsMatchExplicitEXIFHalfTurn() throws {
        let corrected = try RunnerScreenshot.image(png: fixture(orientation: 1), interfaceOrientation: 2)
        let tagged = try ScreenImage(png: fixture(orientation: 3)).image
        XCTAssertEqual(corrected.width, 4)
        XCTAssertEqual(corrected.height, 6)
        XCTAssertEqual(try pixels(corrected), try pixels(tagged))
        XCTAssertNotEqual(try pixels(corrected), try pixels(ScreenImage(png: fixture(orientation: 1)).image))
    }

    func testExplicitEXIFTransformsAreNotAppliedTwice() throws {
        for (exif, interface) in [(3, 2), (6, 4), (8, 3)] {
            let png = try fixture(orientation: exif)
            let expected = try ScreenImage(png: png).image
            let actual = try RunnerScreenshot.image(png: png, interfaceOrientation: interface)
            XCTAssertEqual(actual.width, expected.width)
            XCTAssertEqual(actual.height, expected.height)
            XCTAssertEqual(try pixels(actual), try pixels(expected))
        }
    }

    func testOtherDisplayOrientationsLeaveUprightImagesUnchanged() throws {
        let png = try fixture(orientation: 1)
        let expected = try pixels(ScreenImage(png: png).image)
        for orientation in [1, 3, 4] {
            XCTAssertEqual(try pixels(RunnerScreenshot.image(png: png, interfaceOrientation: orientation)), expected)
        }
    }

    func testInvalidDisplayOrientationAndImageFailClosed() throws {
        let png = try fixture(orientation: 1)
        for orientation in [0, 5, -1] {
            XCTAssertThrowsError(try RunnerScreenshot.image(png: png, interfaceOrientation: orientation))
        }
        XCTAssertThrowsError(try RunnerScreenshot.image(png: Data(), interfaceOrientation: 2))
    }

    private func fixture(orientation: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 4, height: 6, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (index, color) in [
            CGColor(red: 1, green: 0, blue: 0, alpha: 1), CGColor(red: 0, green: 1, blue: 0, alpha: 1),
            CGColor(red: 0, green: 0, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 0, alpha: 1)
        ].enumerated() {
            context.setFillColor(color)
            context.fill(CGRect(x: index % 2 * 2, y: index / 2 * 3, width: 2, height: 3))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func pixels(_ image: CGImage) throws -> Data {
        try ScreenImage(image: image).rgb(
            rect: ScreenRect(CGRect(x: 0, y: 0, width: image.width, height: image.height)),
            screen: ScreenRect(CGRect(x: 0, y: 0, width: image.width, height: image.height)),
            columns: image.width, rows: image.height)
    }
}
