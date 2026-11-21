import Foundation

// Finish each admitted capture on the owning session before selecting its PNG or closing its services.
final class NativeTapFrameWorker {
    private let queue = DispatchQueue(label: "iphone-use.tap-frame", qos: .userInitiated)

    func run<Value>(_ work: () throws -> Value) rethrows -> Value { try queue.sync(execute: work) }
    func drain() { queue.sync {} }

    // Scoped to one tap. A valid frame may establish a new geometry. A failed
    // capture that saw a different display must invalidate any earlier fallback.
    final class DisplayHistory {
        private var previous: NativeDisplay.Geometry?

        func sample(
            _ capture: (@escaping (NativeDisplay) -> Void) throws -> CapturedObservation
        ) throws -> CapturedObservation {
            var changed = false
            do {
                return try capture { display in
                    if let previous = self.previous, previous != display.geometry { changed = true }
                    self.previous = display.geometry
                }
            } catch let error as IPhoneUseError where changed && NativePostActionStability.permitsFallback(error.code) {
                throw IPhoneUseError("capture_context_changed", "Display changed during a failed tap sample",
                    diagnostics: error.diagnostics)
            }
        }
    }
}
