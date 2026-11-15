import Foundation
import CoreGraphics

extension ObservationCache {

    struct Detail {
        let reference: ObservationReference
        let indices: [Int]
        let offset: Int
        let query: String?
    }

    func subtree(_ nodes: [AXNode], root: Int?) -> [Int] {
        guard let root else { return Array(nodes.indices) }
        var included: Set<Int> = [root]
        for node in nodes where node.parent.map({ included.contains($0) }) == true {
            included.insert(node.index)
        }
        return nodes.indices.filter { included.contains($0) }
    }

    func result(_ entry: Entry, detail: Detail?) -> [String: Any] {
        let capture = entry.capture
        let metadata = capture.metadata
        let screenshot = entry.directory.appendingPathComponent("screen.png").path
        let snapshot = entry.directory.appendingPathComponent("snapshot.json").path
        var lines = [
            """
            observation=\(entry.id) refs=\(entry.validity)
            scope=\(metadata["scope"] ?? "unknown")\
             target=\(quoted(metadata["targetBundleId"] ?? NSNull()))\
             foreground=\(quoted(metadata["foregroundBundleId"] ?? NSNull()))
            """,
            """
            screenshot=\(quoted(screenshot))\
             pixels=\(metadata["screenshotWidth"] ?? "?")x\(metadata["screenshotHeight"] ?? "?")\
             screen_points=\(quoted(metadata["screenFrame"] ?? NSNull()))
            """,
            """
            ax=\(metadata["axStatus"] ?? "unavailable")\
             source_truncated=\(metadata["sourceTruncated"] ?? "unknown")\
             ax_started=\(metadata["snapshotStartedAt"] ?? "unknown")\
             ax_finished=\(metadata["snapshotFinishedAt"] ?? "unknown")\
             screenshot_at=\(metadata["screenshotCapturedAt"] ?? "unknown")
            """
        ] + ObservationAcquisition.lines(metadata)
        if let error = metadata["axError"] as? String {
            lines.append(
                "ax_error=\(quoted(String(error.prefix(256))))\(error.count > 256 ? " detail_clipped=true" : "")"
            )
        }
        let footer = "snapshot=\(quoted(snapshot)) (cached source; inspect \(entry.id) for details)"
        appendNativeMetadata(metadata, to: &lines)
        appendContent(entry, detail: detail, lines: &lines)
        if metadata["sourceTruncated"] as? Bool == true {
            lines.append("source_missing=true; uncaptured nodes cannot be expanded from this snapshot")
        }
        lines.append(footer)
        var response: [String: Any] = [
            "observation": entry.id, "refs": entry.validity, "screenshot": screenshot, "snapshot": snapshot,
            "text": lines.joined(separator: "\n")
        ]
        if let query = detail?.query { response["query"] = query }
        let reference = entry.directory.appendingPathComponent("ax-before.png")
        if capture.axComparisonScreenshot != nil {
            if FileManager.default.fileExists(atPath: reference.path) {
                response["axComparisonScreenshot"] = reference.path
            } else {
                response["axComparisonEvidenceError"] = "Could not retain AX comparison screenshot"
            }
        }
        return deliverText(response, entry: entry)
    }

    private func appendNativeMetadata(_ metadata: [String: Any], to lines: inout [String]) {
        if metadata["backend"] as? String == "apple-native" {
            lines.append(
                """
                backend=apple-native coordinate_space=screen_points\
                 pixels_per_point=\(metadata["pointScale"] ?? "unknown")\
                 rotation=\(metadata["displayRotation"] ?? "unknown")
                """
            )
            lines.append(
                """
                device=\(quoted(metadata["deviceID"] ?? NSNull()))\
                 generation=\(quoted(metadata["sessionGeneration"] ?? NSNull()))\
                 capture_started=\(metadata["captureStartedAt"] ?? "unknown")\
                 capture_completed=\(metadata["captureCompletedAt"] ?? "unknown")
                """
            )
            lines.append(
                "foreground=unverified keyboard_state=unknown; locate targets visually in the original screenshot"
            )
            if metadata["snapshotSource"] as? String == "axp_native_snapshot_v1" {
                lines.append(
                    "ax_source=axp ax_scope=application coverage=unknown atomic=false element_actions=false")
                lines.append(
                    "AX refs are for inspect; use screenshot-bound coordinates. "
                        + "AX visibility does not prove hittability.")
            }
            if let stability = metadata["postActionStability"] as? [String: Any] {
                lines.append(
                    """
                    post_action_stable=\(stability["stable"] ?? false)\
                     reason=\(stability["reason"] ?? "unknown"); visual stability does not confirm action success
                    """
                )
            }
        }
    }

    private func appendContent(_ entry: Entry, detail: Detail?, lines: inout [String]) {
        if let detail {
            appendDetail(entry, detail: detail, lines: &lines)
        } else {
            appendCompact(entry, lines: &lines)
        }
    }

    private func appendDetail(_ entry: Entry, detail: Detail, lines: inout [String]) {
        let capture = entry.capture
        var body: [String] = []
        var nextOffset: Int?
        let reference = detail.reference, indices = detail.indices, offset = detail.offset,
            query = detail.query
        let target = reference.node.map { "\(entry.id):e\($0 + 1)" } ?? entry.id
        // A continuation is shell text, not JSON: preserve literal quotes, $, and backticks.
        let queryOption =
            query.map { " --query '" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" } ?? ""
        if let query {
            lines.append(
                """
                inspect=\(target) query=\(quoted(query)) offset=\(offset) matched_nodes=\(indices.count)\
                 searched_nodes=\(subtree(capture.nodes, root: reference.node).count)
                """
            )
            if indices.isEmpty {
                lines.append("no_matches_in_capture=true; this does not prove absence from the UI")
            }
        } else {
            lines.append("inspect=\(target) offset=\(offset) captured_nodes=\(indices.count)")
        }
        for (position, index) in indices.enumerated().dropFirst(offset) {
            let node = capture.nodes[index]
            var attributes = node.attributes
            attributes["ref"] = "\(entry.id):\(node.ref)"
            attributes["role"] = node.role
            if query != nil {
                attributes["parentRef"] = node.parent.map { "\(entry.id):e\($0 + 1)" } as Any? ?? NSNull()
                attributes.removeValue(forKey: "index"); attributes.removeValue(forKey: "parent")

            }
            let line = quoted(attributes)
            if body.count == 20 {
                nextOffset = position; break
            }
            body.append(line)
        }
        lines += body
        if let nextOffset {
            lines.append(
                "more: inspect \(target)\(queryOption) --offset \(nextOffset) (same cached snapshot)")
        }
    }

    private func appendCompact(_ entry: Entry, lines: inout [String]) {
        let capture = entry.capture
        let projection = PresentedAX.project(capture)
        let compact = CompactAX.render(capture.nodes, including: projection.indices)
        lines.append(
            "presentation=viewport hierarchy=\(projection.hierarchyKnown ? "modal_filtered" : "unknown") "
                + "geometry=\(projection.geometryKnown ? "screen_clipped" : "unknown") "
                + "omitted_nodes=\(capture.nodes.count - projection.indices.count); "
                + "visibility does not prove hittability")
        if projection.semanticCandidatesOnly {
            lines.append("presentation_selection=semantic_candidates_and_keyboard_context; "
                + "independent_child_controls=\(projection.unqueriedChildControls) with unknown visibility; "
                + "other structural nodes remain cached")
        }
        if projection.omittedKeyboardCharacters > 0 {
            lines.append("keyboard_character_keys_omitted=\(projection.omittedKeyboardCharacters); "
                + "full nodes and native visible remain available through inspect")
        }
        if let collection = capture.metadata["axCollection"] as? [String: Any],
            collection["visibilityCoverage"] as? String == "semantic_candidates" {
            lines.append("ax_visibility=semantic_candidates; unqueried_visible=unknown; "
                + "supplemental_nodes=\(collection["supplementalNodeCount"] ?? 0) hierarchy=unknown")
        }
        lines += compact
    }
}
