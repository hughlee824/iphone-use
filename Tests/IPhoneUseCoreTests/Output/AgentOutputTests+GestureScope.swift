import XCTest
@testable import IPhoneUseCore

extension AgentOutputTests {
    func testNativeGestureDiagnosticsDoNotBecomeFalseRejectionReasons() throws {
        for start in [0.0, 0.1] {
            let check: [String: Any] = [
                "accepted": start == 0, "screenChange": 0.5, "maxScreenChange": 0.01,
                "regionChanges": [start, 0.2], "maxRegionChange": 0.0,
                "validationScope": "native_gesture_regions",
                "diagnosticOnlyGlobal": true, "diagnosticOnlyRegions": [1]
            ]
            let compact = AgentOutput.summarize(["result": ["screenGuard": check]])
            let summary = try XCTUnwrap(compact["agentSummary"] as? [String: Any])
            let comparison = try XCTUnwrap(summary["comparison"] as? [String: Any])
            XCTAssertEqual(comparison["mismatches"] as? [String], start == 0 ? [] : ["protected_region_changed"])
            XCTAssertEqual(comparison["screenChange"] as? Double, 0.5)
            XCTAssertEqual(comparison["diagnosticOnlyRegions"] as? [Int], [1])
        }
    }
}
