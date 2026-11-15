import Foundation

// The session holds SessionDeviceLock for this object's whole lifetime. The journal lives in
// a persistent, per-user root so state/config overrides cannot bypass previous cleanup.
final class AXAutomation {
    typealias Operation = (URL, String, Bool, @escaping () -> Bool) throws -> [String: Any]
    let device: String
    let journal: URL
    private let operation: Operation
    private var pending = false
    private var journalReady = false
    private var started = false
    private var closed = false
    private var cleanup: [String: Any] = [:]
    private(set) var status: [String: Any] = ["state": "not_started", "cleanupPending": false]

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".iphone-use/ax-automation")
    }

    init(
        device: String, root: URL = AXAutomation.defaultRoot, ownership: SessionDeviceLock? = nil,
        operation: Operation? = nil
    ) {
        self.device = device
        journal = root.appendingPathComponent("ax-automation-\(device).json")
        self.operation = operation ?? { [weak ownership] journal, token, enabled, cancelled in
            guard let ownership else {
                throw IPhoneUseError("ax_automation_owner_unavailable", "AX mutation has no owning control session")
            }
            return try AXAutomationProcess(ownership: ownership).run(
                device: device, journal: journal, token: token, enabled: enabled, cancelled: cancelled)
        }
    }

    func start(cancelled: @escaping () -> Bool) {
        guard !started, !closed else { return }
        started = true
        do {
            try SessionPaths.secureDirectory(journal.deletingLastPathComponent())
            journalReady = true
        } catch {
            // An inaccessible directory may contain an older obligation. Do not claim a clean
            // device or write through an unsafe journal directory.
            pending = true
            status = ["state": "cleanup_pending", "cleanupPending": true, "error": String(describing: error)]
            return
        }
        // A dead host may have left an enable helper in flight. Changing the token fences helpers
        // that have not dispatched; the helper's mutation lock serializes those already in flight.
        if FileManager.default.fileExists(atPath: journal.path) {
            pending = true
            let recovery = transition(enabled: false, cancelled: { false })
            status["recovery"] = recovery
            guard recovery["acknowledged"] as? Bool == true else {
                status["state"] = "cleanup_pending"
                status["cleanupPending"] = true
                return
            }
        }
        guard !cancelled() else { status["state"] = "cancelled"; return }
        let enable = transition(enabled: true, cancelled: cancelled)
        status["enable"] = enable
        if enable["acknowledged"] as? Bool == true {
            status["state"] = "enabled"
        } else {
            // A failed/unknown write or notification must not leave an unowned enhancement.
            // This is a compensating false write, never a retry of the enable operation.
            let rollback = pending ? transition(enabled: false, cancelled: { false }) : [:]
            status["rollback"] = rollback
            status["state"] = pending ? "cleanup_pending" : "unavailable"
        }
        status["cleanupPending"] = pending
    }

    func close() -> [String: Any] {
        guard !closed else { return cleanup }
        closed = true
        let disable = pending ? transition(enabled: false, cancelled: { false }) : [:]
        cleanup = ["required": !disable.isEmpty, "acknowledged": !pending,
                   "cleanupPending": pending, "disable": disable]
        status["state"] = pending ? "cleanup_pending" : "closed"
        status["cleanupPending"] = pending
        return cleanup
    }

    private func transition(enabled: Bool, cancelled: @escaping () -> Bool) -> [String: Any] {
        guard journalReady else {
            return ["acknowledged": false, "error": "AX cleanup journal unavailable", "cleanupPending": pending]
        }
        let token = UUID().uuidString
        do {
            // Persist responsibility before launching any process that may write. Do not clear
            // on timeout, missing reply, failed notification, or failure to remove the marker.
            try saveJSON(["device": device, "token": token, "enabled": enabled], to: journal)
            pending = true
            var facts = try operation(journal, token, enabled, cancelled)
            let acknowledged = facts["writeAcknowledged"] as? Bool == true
                && facts["notificationAcknowledged"] as? Bool == true
            if acknowledged, !enabled {
                try FileManager.default.removeItem(at: journal)
                pending = false
            }
            facts["acknowledged"] = acknowledged
            return facts
        } catch {
            return ["acknowledged": false, "error": String(describing: error), "cleanupPending": pending]
        }
    }
}
