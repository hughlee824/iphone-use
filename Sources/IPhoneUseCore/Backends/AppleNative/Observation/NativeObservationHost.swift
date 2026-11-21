import Foundation
import AppleNativeBridge

public enum NativeObservationHost {
    public static func run(device: String, kind: String, generation: String) throws {
        guard UUID(uuidString: generation) != nil, ["ax", "screenshot"].contains(kind) else {
            throw IPhoneUseError("invalid_arguments", "Invalid observation worker identity")
        }
        var error: NSError?
        guard ASRunObservationWorker(device, kind, generation, &error) else {
            throw error ?? IPhoneUseError("observation_worker_unavailable", "Observation service failed")
        }
    }
}
