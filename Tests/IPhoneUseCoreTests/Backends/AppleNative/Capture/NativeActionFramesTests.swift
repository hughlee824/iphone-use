import Foundation
import XCTest
@testable import IPhoneUseCore

final class NativeActionFramesTests: XCTestCase {
    func testCachedPixelsPreserveFrameComparison() throws {
        let fixture = NativePostActionStabilityTests()
        let raw = try fixture.frame()
        let metadata = raw.metadata.merging(["deviceID": "d", "sessionGeneration": "s",
            "displayUniqueID": "display", "screenFrame": ["width": 40, "height": 80]]) { _, new in new }
        let first = CapturedObservation(nodes: [], metadata: metadata, screenshot: raw.screenshot)
        try compare(first, first)
        let changed = try fixture.frame(220)
        try compare(first, CapturedObservation(nodes: [], metadata: metadata, screenshot: changed.screenshot))
    }

    private func compare(_ first: CapturedObservation, _ second: CapturedObservation) throws {
        let expected = try AXPScreenComparison(first, second)
        XCTAssertEqual(expected.result["pixelComparisonPerformed"] as? Bool, true)
        var left = first, right = second
        left.validatedPixels = try first.fingerprint(); right.validatedPixels = try second.fingerprint()
        let actual = try AXPScreenComparison(left, right)
        XCTAssertEqual(NSDictionary(dictionary: expected.result), NSDictionary(dictionary: actual.result))
    }
}
