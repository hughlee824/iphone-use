import Foundation
import CoreGraphics
import ImageIO

public enum RunnerScreenshot {
    public static func image(png: Data, interfaceOrientation: Int) throws -> CGImage {
        guard (1...4).contains(interfaceOrientation),
            let source = CGImageSourceCreateWithData(png as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw ScreenGuard.Failure.invalidImage }
        let image = try ScreenImage(png: png).image
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        // XCTest on Duo can return native-axis pixels tagged .up for an
        // upside-down display. The selected display context supplies the
        // missing half-turn. Honor explicit EXIF transforms exactly once;
        // never apply this workaround to CoreDevice or ordinary PNG decoding.
        guard interfaceOrientation == 2, orientation == 1 else { return image }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ScreenGuard.Failure.invalidImage }
        context.translateBy(x: CGFloat(image.width), y: CGFloat(image.height))
        context.rotate(by: .pi)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw ScreenGuard.Failure.invalidImage }
        return result
    }
}
