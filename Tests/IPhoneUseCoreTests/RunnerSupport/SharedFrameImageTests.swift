import XCTest
import CoreGraphics
import ImageIO
@testable import IPhoneUseRunnerSupport

final class SharedFrameImageTests: XCTestCase {
    func testNormalizedPixelsPreserveSamplingAcrossImageFormats() throws {
        for space in [CGColorSpace.sRGB, CGColorSpace.displayP3] {
            for bits in [8, 16] {
                for alpha in [false, true] {
                    for orientation in [1, 3, 6, 8] {
                        try compare(png(space: space, bits: bits, alpha: alpha, orientation: orientation))
                    }
                }
            }
        }
    }

    func testImageRetainsPixelsAfterFingerprintReleaseAndHandlesSmallImages() throws {
        XCTAssertEqual(
            try FrameFingerprint(png: png(width: 1, height: 1)).hash,
            "ebad801d37b763e7e9cddf83733938116f71a75f31f7e4fcbe3dcf235ed37350")
        for size in [(1, 1), (1, 7), (9, 1), (17, 31)] {
            let data = try png(width: size.0, height: size.1)
            let image = try autoreleasepool { try FrameFingerprint(png: data).normalizedImage() }
            let screen = ScreenRect(CGRect(x: 0, y: 0, width: size.0, height: size.1))
            XCTAssertEqual(
                try image.rgb(rect: screen, screen: screen, columns: 32, rows: 64),
                try ScreenImage(png: data).rgb(rect: screen, screen: screen, columns: 32, rows: 64))
        }
    }

    private func compare(_ data: Data) throws {
        let original = data
        let fingerprint = try FrameFingerprint(png: data)
        let shared = try fingerprint.normalizedImage(), old = try ScreenImage(png: data)
        let screen = ScreenRect(CGRect(x: 0, y: 0, width: old.image.width, height: old.image.height))
        let inset = ScreenRect(CGRect(x: 1.25, y: 2.25, width: 11.5, height: 13.5))
        for (rect, columns, rows) in [(screen, 32, 64), (screen, 7, 9), (inset, 5, 7)] {
            XCTAssertEqual(
                try shared.rgb(rect: rect, screen: screen, columns: columns, rows: rows),
                try old.rgb(rect: rect, screen: screen, columns: columns, rows: rows))
        }
        XCTAssertEqual(
            try shared.areaRGB(rect: screen, screen: screen, columns: 7, rows: 9),
            try old.areaRGB(rect: screen, screen: screen, columns: 7, rows: 9))
        XCTAssertEqual(data, original)
        XCTAssertEqual(shared.image.width, old.image.width)
        XCTAssertEqual(shared.image.height, old.image.height)
    }

    private func png(
        width: Int = 37, height: Int = 53, space: CFString = CGColorSpace.sRGB,
        bits: Int = 8, alpha: Bool = false, orientation: Int = 1
    ) throws -> Data {
        let channels = 4, bytes = bits / 8
        var pixels = Data(count: width * height * channels * bytes)
        pixels.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            for index in 0..<(width * height) {
                for channel in 0..<4 {
                    let value = channel == 3 ? (alpha ? (index * 13) % 256 : 255)
                        : (index * (channel + 3) * 17) % 256
                    let offset = (index * 4 + channel) * bytes
                    buffer[offset] = UInt8(value)
                    if bytes == 2 {
                        buffer[offset + 1] = channel == 3 && !alpha ? 255 : UInt8((value * 7) % 256)
                    }
                }
            }
        }
        assertAlpha(pixels, bits: bits, transparent: alpha)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * 4,
            bytesPerRow: width * 4 * bytes, space: try XCTUnwrap(CGColorSpace(name: space)),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue
                | (bits == 16 ? CGBitmapInfo.byteOrder16Big.rawValue : CGBitmapInfo.byteOrder32Big.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyDepth] as? Int, bits)
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, width)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, height)
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, orientation)
        let decoded = try ScreenImage(png: data as Data).image
        XCTAssertEqual(decoded.bitsPerComponent, bits)
        XCTAssertEqual(decoded.colorSpace?.name, space)
        XCTAssertEqual(decoded.width, [6, 8].contains(orientation) ? height : width)
        XCTAssertEqual(decoded.height, [6, 8].contains(orientation) ? width : height)
        return data as Data
    }

    private func assertAlpha(_ pixels: Data, bits: Int, transparent: Bool) {
        // Check the source precision before an 8-bit conversion could hide 0xFFF9.
        let bytes = bits / 8
        let samples = stride(from: 3 * bytes, to: pixels.count, by: 4 * bytes).map { offset in
            bytes == 1 ? UInt16(pixels[offset])
                : UInt16(pixels[offset]) << 8 | UInt16(pixels[offset + 1])
        }
        let opaque: UInt16 = bits == 16 ? 0xFFFF : 0xFF
        if transparent {
            XCTAssertTrue(samples.contains { $0 < opaque }, "Transparent fixture must contain transparency")
        } else {
            XCTAssertEqual(Set(samples), [opaque], "Opaque fixture must have maximum alpha in every pixel")
        }
    }
}
