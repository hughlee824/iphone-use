import Foundation

// One bounded mailbox per process generation. Old readers can only write to their own mailbox.
final class ObservationWorkerOutput {
    private let lock = NSLock()
    private var partial = Data()
    private var scannedBytes = 0
    private var frames: [Data] = []
    private var queuedBytes = 0
    private var failure = false
    private var ended = false
    static let maximumFrame = 48 * 1024 * 1024

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !failure, !ended else { return }
        partial.append(data)
        while true {
            // Offsets, not Data indices: removing a complete frame can change
            // startIndex. Previously scanned bytes cannot acquire a delimiter.
            let start = partial.index(partial.startIndex, offsetBy: scannedBytes)
            guard let end = partial[start...].firstIndex(of: 10) else {
                scannedBytes = partial.count
                break
            }
            let size = partial.distance(from: partial.startIndex, to: end)
            guard size <= Self.maximumFrame, frames.count < 4,
                queuedBytes + size <= 64 * 1024 * 1024 else { failure = true; partial = Data(); return }
            let frame = Data(partial.prefix(size))
            frames.append(frame); queuedBytes += size
            partial.removeSubrange(partial.startIndex...end)
            scannedBytes = 0
        }
        if partial.count > Self.maximumFrame { failure = true; partial = Data() }
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        if !partial.isEmpty { failure = true }
        ended = true
    }
    func next() throws -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        guard !failure else { throw IPhoneUseError("observation_worker_invalid", "Invalid observation worker output") }
        if !frames.isEmpty {
            let data = frames.removeFirst(); queuedBytes -= data.count
            return try jsonObject(data)
        }
        if ended { throw IPhoneUseError("observation_worker_closed", "Observation connection closed") }
        return nil
    }
}
