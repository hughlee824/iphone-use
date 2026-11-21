import Foundation
import XCTest
@testable import IPhoneUseCore

extension AXPObservationTests {
    func testPersistentLeaseDoesNotClaimPerReadConnectionClosure() throws {
        var value = payload()
        value.removeValue(forKey: "cleanup")
        XCTAssertThrowsError(try AXPSnapshot.decode(value, device: "device"))
        value["connectionLease"] = ["generation": UUID().uuidString, "requestID": UUID().uuidString, "state": "current"]
        let decoded = try AXPSnapshot.decode(value, device: "device")
        XCTAssertEqual(decoded.cleanup["deferredToSession"] as? Bool, true)
        XCTAssertNil(decoded.cleanup["connectionClosed"])
        value["connectionLease"] = ["generation": UUID().uuidString, "requestID": UUID().uuidString, "state": "retired"]
        XCTAssertThrowsError(try AXPSnapshot.decode(value, device: "device"))
    }
}
