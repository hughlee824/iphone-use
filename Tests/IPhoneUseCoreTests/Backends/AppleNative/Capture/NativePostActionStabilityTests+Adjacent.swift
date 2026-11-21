import XCTest
import IPhoneUseRunnerSupport
@testable import IPhoneUseCore

extension NativePostActionStabilityTests {
    func testTapReturnsSecondOfFirstMatchingPairWithoutSleeping() throws {
        let old = try frame(), fresh = try frame(230), rotated = try frame(230, rotation: "rot270")
        for sequence in [[old, old], [old, fresh, fresh], [old, fresh, rotated, rotated]] {
            var time = 0.0, count = 0
            let result = try NativePostActionStability.capture(
                policy: .adjacentTap, now: { time }, pause: { _ in XCTFail("unexpected wait") },
                checkCancellation: {}, sample: { _ in
                    let image = try XCTUnwrap(sequence.dropFirst(count).first)
                    count += 1; time += 0.2
                    return CapturedObservation(nodes: [], metadata: image.metadata.merging(["sample": count]) { $1 },
                        screenshot: image.screenshot)
                })
            XCTAssertEqual(count, sequence.count)
            XCTAssertEqual(result.metadata["sample"] as? Int, count)
            XCTAssertEqual(facts(result)["requiredFrames"] as? Int, 2)
            XCTAssertEqual(facts(result)["stable"] as? Bool, true)
        }
    }

    func testTapBudgetReturnsLatestFrameWhenPairNeverMatches() throws {
        let first = try frame(), second = try frame(230)
        var time = 0.0, count = 0
        let result = try NativePostActionStability.capture(
            policy: .adjacentTap, now: { time }, checkCancellation: {}, sample: { deadline in
                count += 1
                if count > 4 {
                    time = deadline
                    throw IPhoneUseError("observation_worker_timeout", "screenshot timed out")
                }
                time += 0.3
                return count.isMultiple(of: 2) ? second : first
            })
        XCTAssertEqual(count, 5)
        XCTAssertEqual(facts(result)["stable"] as? Bool, false)
        XCTAssertEqual(result.screenshot, second.screenshot)
    }

    func testTapKeepsFinalInFlightFrameWithoutClaimingStability() throws {
        let first = try frame(), different = try frame(230)
        let rotated = try frame(230, rotation: "rot270")
        for late in [first, different, rotated] {
            var time = 0.0, count = 0
            let result = try NativePostActionStability.capture(
                policy: .adjacentTap, now: { time }, checkCancellation: {}, sample: { cutoff in
                    XCTAssertLessThan(time, cutoff)
                    count += 1
                    time = count == 1 ? 1.499 : 1.8
                    let image = count == 1 ? first : late
                    return CapturedObservation(nodes: [], metadata: image.metadata.merging(["sample": count]) { $1 },
                        screenshot: image.screenshot)
                })
            XCTAssertEqual(count, 2)
            XCTAssertEqual(result.metadata["sample"] as? Int, 2)
            XCTAssertEqual(result.screenshot, late.screenshot)
            XCTAssertEqual(facts(result)["timeoutMs"] as? Double, 1500)
            XCTAssertEqual(facts(result)["stable"] as? Bool, false)
        }
    }

    func testFirstInFlightFrameMayBeTheOnlyValidFrame() throws {
        let image = try frame()
        var time = 0.0
        let result = try NativePostActionStability.capture(
            policy: .adjacentTap, now: { time }, checkCancellation: {}, sample: { _ in
                time = 2
                return image
            })
        XCTAssertEqual(result.screenshot, image.screenshot)
        XCTAssertEqual(facts(result)["samples"] as? Int, 1)
        XCTAssertEqual(facts(result)["stable"] as? Bool, false)
    }

    func testWorkerInterruptionCannotPublishEarlierTapFrame() throws {
        let image = try frame()
        for cancelled in [true, false] {
            var time = 0.0, count = 0
            XCTAssertThrowsError(try NativePostActionStability.capture(
                policy: .adjacentTap, now: { time }, checkCancellation: {
                    if cancelled && count == 2 { throw IPhoneUseError("native_cancelled", "closed") }
                }, sample: { deadline in
                    count += 1
                    if count == 1 { time += 0.2; return image }
                    time = cancelled ? deadline : 0.5
                    throw IPhoneUseError("observation_worker_timeout", "interrupted")
                })) {
                let expected = cancelled ? "native_cancelled" : "observation_worker_timeout"
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, expected)
            }
        }
    }

    func testTapCannotReturnOldFrameAfterContextInvalidation() throws {
        let image = try frame()
        var time = 0.0, count = 0
        XCTAssertThrowsError(try NativePostActionStability.capture(
            policy: .adjacentTap, now: { time }, pause: { time += $0 }, checkCancellation: {},
            sample: { deadline in
                count += 1
                if count == 1 { time += 0.2; return image }
                time = deadline
                throw IPhoneUseError("capture_context_changed", "rotated")
            })) { XCTAssertEqual(($0 as? IPhoneUseError)?.code, "post_action_capture_timeout") }
    }

    func testFinalCaptureFailureRequiresAValidFrameAndCurrentIdentity() throws {
        let image = try frame()
        for hasBaseline in [false, true] {
            for code in ["native_screenshot_invalid", "observation_worker_stale", "native_cancelled"] {
                var time = 0.0
                let capture = {
                    try NativePostActionStability.capture(
                        policy: .adjacentTap, now: { time }, checkCancellation: {}, sample: { cutoff in
                            if hasBaseline && time == 0 { time = 1; return image }
                            time = cutoff + 0.2
                            throw IPhoneUseError(code, "final request failed")
                        })
                }
                if code == "native_screenshot_invalid" && hasBaseline {
                    let result = try capture()
                    XCTAssertEqual(result.screenshot, image.screenshot)
                    XCTAssertEqual(self.facts(result)["stable"] as? Bool, false)
                } else {
                    XCTAssertThrowsError(try capture()) {
                        let expected = code == "native_screenshot_invalid" ? "post_action_capture_timeout" : code
                        XCTAssertEqual(($0 as? IPhoneUseError)?.code, expected)
                    }
                }
            }
        }
    }

    func testTapPairHonorsExplicitIgnoreRegion() throws {
        let image = try frame(), different = try frame(patch: true)
        var count = 0, time = 0.0
        let result = try NativePostActionStability.capture(
            policy: .adjacentTap, ignoring: ScreenRect(CGRect(x: 4, y: 4, width: 7, height: 7)),
            now: { time }, checkCancellation: {}, sample: { _ in
                count += 1; time += 0.2
                return count == 1 ? image : different
            })
        XCTAssertEqual(count, 2)
        XCTAssertEqual(facts(result)["stable"] as? Bool, true)
        XCTAssertEqual(result.screenshot, different.screenshot)
    }
}
