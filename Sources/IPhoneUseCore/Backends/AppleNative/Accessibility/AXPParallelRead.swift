import Foundation

// One owned, bounded helper read. Always join before publishing or returning an error.
// The read closure must honor cancellation; AXPReader also enforces its own process deadline.
final class AXPParallelRead {
    struct Reply {
        let startedAt: Double
        let finishedAt: Double
        let payload: Result<[String: Any], Error>
    }

    private let group = DispatchGroup()
    private let cancellation = NativeCancellation()
    private var reply: Reply?

    init(read: @escaping (() -> Bool) throws -> [String: Any]) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.group.leave() }
            let started = Date().timeIntervalSince1970
            let payload = Result { try read { self.cancellation.isCancelled } }
            self.reply = Reply(startedAt: started, finishedAt: Date().timeIntervalSince1970, payload: payload)
        }
    }

    func cancel() { cancellation.cancel() }

    func join() -> Reply {
        group.wait() // AXPReader terminates and drains its child before completing.
        return reply! // Exactly one writer, synchronized by DispatchGroup.
    }
}
