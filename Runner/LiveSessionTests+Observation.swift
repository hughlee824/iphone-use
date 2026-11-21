import IPhoneUseRunnerSupport
import ImageIO
import Network
import XCTest
import Darwin

extension LiveSessionTests {

    @MainActor
    func selectedScreen() throws -> XCUIScreen {
        guard let displayID = commandDisplayID else { throw CommandError("display_unavailable") }
        let matches = try XCUIScreen.screens.filter { try RunnerAXBinding.displayID(of: $0).uint64Value == displayID }
        guard matches.count == 1 else { throw CommandError("display_unavailable") }
        return matches[0]
    }

    struct CapturedScreen {
        let png: Data
        let width: Int
        let height: Int
    }

    @MainActor
    func captureScreen() throws -> CapturedScreen {
        let began = ProcessInfo.processInfo.systemUptime
        let screenshot = try selectedScreen().screenshot()
        addTiming("screenshotRequest", since: began)
        let pngBegan = ProcessInfo.processInfo.systemUptime
        let png = screenshot.pngRepresentation
        addTiming("screenshotPNG", since: pngBegan)
        let normalizeBegan = ProcessInfo.processInfo.systemUptime
        let encoded = try RunnerScreenshot.encoded(
            png: png, interfaceOrientation: commandDisplayContext?.orientation ?? 0)
        addTiming("normalizePNG", since: normalizeBegan)
        phaseTimings[encoded.reencoded ? "reencodedFrames" : "originalPNGFrames", default: 0] += 1
        return CapturedScreen(png: encoded.png, width: encoded.width, height: encoded.height)
    }

    func addTiming(_ phase: String, since began: TimeInterval) {
        phaseTimings[phase + "Ms", default: 0] += (ProcessInfo.processInfo.systemUptime - began) * 1000
    }

    func freshSnapshot(_ element: XCUIElement) throws -> XCUIElementSnapshot {
        guard let snapshot = try RunnerAXBinding.snapshot(of: element) as? XCUIElementSnapshot else {
            throw CommandError("snapshot_unavailable", requiresObservation: true)
        }
        return snapshot
    }

    @MainActor
    func waitForStableFrame() async throws {
        let began = ProcessInfo.processInfo.systemUptime
        defer { addTiming("postActionSampling", since: began) }
        var stability = FrameStability(
            startedAt: ProcessInfo.processInfo.systemUptime,
            context: postInputContext, textFields: postInputTextFields)
        frameStability = stability
        while stability.remaining(at: ProcessInfo.processInfo.systemUptime) > 0 {
            try Task.checkCancellation()
            let began = ProcessInfo.processInfo.systemUptime
            let screenshot = try captureScreen()
            let captureFinished = ProcessInfo.processInfo.systemUptime
            let capturedAt = Date().timeIntervalSince1970
            let png = screenshot.png
            let compareBegan = ProcessInfo.processInfo.systemUptime
            let fingerprint = try FrameFingerprint(png: png)
            stability.record(
                frame: fingerprint, png: png, capturedAt: captureFinished,
                processedAt: ProcessInfo.processInfo.systemUptime)
            addTiming("frameComparison", since: compareBegan)
            frameStability = stability
            actionFrame = ActionFrame(png: png, capturedAt: capturedAt, fingerprint: fingerprint)
            try checkIssues()
            if stability.stable || stability.observationReady { return }
            let now = ProcessInfo.processInfo.systemUptime
            let delay = min(
                max(0, FrameStability.sampleInterval - (now - began)), stability.remaining(at: now))
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
        throw CommandError(
            "post_action_capture_timeout", requiresObservation: true,
            message:
                "Input completed but insufficient post-action frames were captured; do not replay the action")
    }

    // Pixel-analysis boundaries only, never proof of focus. No AX focus traversal.
    func visibleTextFields(root: XCUIElement, context: ScreenContext) -> [ScreenRect] {
        guard context.valid, context.keyboardCount == 1, let snapshot = try? freshSnapshot(root) else {
            return []
        }
        let fields = RunnerAXTree.flatten(snapshot, children: { $0.children }).compactMap { entry -> ScreenRect? in
            let node = entry.node
            let frame = ScreenRect(node.frame)
            guard [XCUIElement.ElementType.textField, .secureTextField, .textView, .searchField].contains(
                node.elementType), node.isEnabled, frame.valid, context.scope.cgRect.contains(frame.cgRect)
            else { return nil }
            return frame
        }
        return fields.count <= 8 ? fields : []
    }

    @MainActor
    private func captureNodes(_ root: XCUIElement) throws -> [[String: Any]] {
        let tree = RunnerAXTree.flatten(try freshSnapshot(root), children: { $0.children })
        var references = RunnerAXReferences<NSObject>()
        let nodes: [[String: Any]] = try tree.enumerated().map { index, entry in
            let node = entry.node
            let frame = node.frame
            var attributes: [String: Any] = [
                "index": index, "parent": entry.parent.map { $0 as Any } ?? NSNull(),
                "identityToken": references.register(try RunnerAXBinding.identity(of: node)),
                "type": node.elementType.rawValue, "identifier": node.identifier,
                "label": node.label, "value": node.value ?? NSNull(), "enabled": node.isEnabled,
                "frame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
            ]
            if [.textField, .secureTextField, .textView, .searchField].contains(node.elementType) {
                attributes["keyboardFocus"] = observedKeyboardFocus(node, root: root) as Any? ?? NSNull()
            }
            return attributes
        }
        observedReferences = references
        return nodes
    }

    @MainActor
    private func observedKeyboardFocus(_ node: XCUIElementSnapshot, root: XCUIElement) -> Bool? {
        // Bind by AX identity, never by label or position. This is advisory observation
        // data; performInput still resolves the target and reads focus before dispatch.
        do {
            guard let element = try RunnerAXBinding.bind(
                snapshot: node, query: root.descendants(matching: .any)) as? XCUIElement,
                try RunnerAXBinding.identity(of: node).isEqual(
                    RunnerAXBinding.identity(of: freshSnapshot(element))) else { return nil }
            return try RunnerAXBinding.keyboardFocus(of: element).boolValue
        } catch { return nil }
    }

    @MainActor
    func observe(
        _ app: XCUIApplication?, root: XCUIElement?, scope: String, error: String? = nil
    ) throws -> [String: Any] {
        let snapshotTime = Date().timeIntervalSince1970
        var nodes: [[String: Any]] = []
        observedReferences = RunnerAXReferences()
        var axError = error
        if let root {
            let axBegan = ProcessInfo.processInfo.systemUptime
            defer { addTiming("axCapture", since: axBegan) }
            do {
                nodes = try captureNodes(root)
            } catch { axError = String(describing: error) }
        }
        let snapshotFinished = Date().timeIntervalSince1970
        let frame = commandDisplayContext?.screen.cgRect
        let contextBegan = ProcessInfo.processInfo.systemUptime
        var context: Any = NSNull()
        if let app, let root,
            let encoded = try? JSONEncoder().encode(screenContext(app: app, root: root)),
            let object = try? JSONSerialization.jsonObject(with: encoded) {
            context = object
        }
        addTiming("screenContext", since: contextBegan)
        let screenshot = try captureScreen()
        return [
            "bundleId": scope == "systemAlert"
                ? "com.apple.springboard" : (app != nil ? currentBundleID as Any? ?? NSNull() : NSNull()),
            "targetBundleId": currentBundleID as Any? ?? NSNull(), "scope": scope,
            "foregroundBundleId": ["app", "appAlert"].contains(scope)
                ? currentBundleID as Any? ?? NSNull() : NSNull(),
            "appState": app.map { $0.state.rawValue as Any } ?? NSNull(),
            "screenFrame": frame.map {
                ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] as Any
            }
                ?? NSNull(),
            "displayID": commandDisplayID as Any? ?? NSNull(),
            "coordinateSpace": "screen_points", "nodes": nodes, "truncated": false,
            "snapshotSource": "explicit_modal_standard_attributes_v1",
            "screenContext": context,
            "axStatus": nodes.isEmpty ? "unavailable" : "available", "axError": axError as Any? ?? NSNull(),
            "snapshotStartedAt": snapshotTime, "snapshotFinishedAt": snapshotFinished,
            "screenshotCapturedAt": Date().timeIntervalSince1970,
            "screenshotWidth": screenshot.width,
            "screenshotHeight": screenshot.height,
            "screenshotBase64": screenshot.png.base64EncodedString()
        ]
    }
}
