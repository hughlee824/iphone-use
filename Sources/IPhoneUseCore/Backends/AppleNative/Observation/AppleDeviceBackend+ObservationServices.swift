import Foundation

extension AppleDeviceBackend {
    func prepareObservations(hardware: [String: Any]) {
        guard let cli else { return }
        // Optional AX preparation failure never prevents screenshot-only use.
        try? axpReader?.prepare(device: cli.device, cancelled: { self.cancellation.isCancelled })
        if NativeScreenshotReader.supports(hardware) {
            let screen = NativeScreenshotReader(device: cli.device)
            do {
                try screen.worker.prewarm(cancelled: { self.cancellation.isCancelled })
                cli.nativeScreenshot = screen
            } catch { _ = screen.worker.close() }
        }
    }
    func closeObservations() -> [String: Any] {
        let accessibility = axpReader?.close() ?? [:]
        let screen = cli?.nativeScreenshot?.worker.close() ?? [:]
        return ["ax": accessibility, "screenshot": screen, "released": released(accessibility) && released(screen)]
    }
    private func released(_ facts: [String: Any]) -> Bool {
        facts.isEmpty || (facts["connectionClosed"] as? Bool == true && facts["tunnelClosed"] as? Bool == true)
    }
}
