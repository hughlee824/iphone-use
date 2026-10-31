import Foundation

// One shared encode serves the largest recently active viewer. Entries expire
// when a tab stops requesting frames; arbitrary client IDs cannot grow storage.
struct NativePreviewDemand {
    private var viewers: [UUID: (edge: Int, seen: Double)] = [:]
    var longEdge: Int { viewers.values.map(\.edge).max() ?? 960 }

    mutating func expire(now: Double) {
        viewers = viewers.filter { now - $0.value.seen < 5 }
    }

    mutating func update(query: [URLQueryItem], now: Double) -> Bool {
        expire(now: now)
        let edges = query.filter { $0.name == "longEdge" }, ids = query.filter { $0.name == "viewer" }
        if edges.isEmpty && ids.isEmpty { return true }
        guard edges.count == 1, ids.count == 1,
            let edge = edges[0].value.flatMap(Int.init), (0...16384).contains(edge),
            let id = ids[0].value.flatMap(UUID.init(uuidString:)) else { return false }
        if edge == 0 { viewers.removeValue(forKey: id); return true }
        guard viewers[id] != nil || viewers.count < 8 else { return false }
        viewers[id] = (edge, now)
        return true
    }
}

extension NativePreview {
    func refreshResolution() {
        demand.expire(now: ProcessInfo.processInfo.systemUptime)
        guard requestedLongEdge != demand.longEdge else { return }
        requestedLongEdge = demand.longEdge
        resolutionRevision += 1
        // Quiet screens need a new encode too; keep the old JPEG visible until
        // the replacement is ready, without changing stream ownership.
        lastSubmittedFrameAt = nil
    }
}
