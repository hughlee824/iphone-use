import Foundation

extension HostRequestExecution {
    func recordAdmission() {
        guard appAction || action != nil || ["text-finish", "text-prepare"].contains(operation) else { return }
        var facts: [String: Any] = ["operation": operation, "phase": "admitted", "requestID": diagnosticID]
        facts["sourceObservation"] = action?.reference.observation ?? reference?.observation
        // A missing final event says nothing about whether an input reached the device.
        try? host.diagnostics?.event(facts, level: .info)
    }

    func recordEvent(elapsedMs: Double, guardPNG: Data?) {
        guard appAction || action != nil || ["observe", "text-finish", "text-prepare"].contains(operation) else {
            return
        }
        var result = response["result"] as? [String: Any] ?? [:]
        let source = action?.reference.observation ?? reference?.observation
        attachActionIdentity(to: &result, source: source)
        guard let diagnostics = host.diagnostics else {
            response["eventRecordingError"] = "diagnostics_unavailable"
            return
        }
        let attached = response["observation"] as? [String: Any]
        let observed = operation == "observe" ? result : attached?["result"] as? [String: Any]
        let observedID = observed?["observation"] as? String
        let entry = observations.entries.last { $0.id == observedID }
        let eventID = diagnosticID
        var facts: [String: Any] = [
            "operation": operation, "phase": "finished", "requestID": eventID, "elapsedMs": elapsedMs
        ]
        facts["sourceObservation"] = source
        facts["targetElement"] = action?.reference.node.map { $0 + 1 }
        facts["followingAction"] = (request["followingAction"] as? String).flatMap { UUID(uuidString: $0)?.uuidString }
        facts["observation"] = observedID
        facts["observationRole"] = observedID.map { _ in
            operation == "observe" ? "observe" :
                attached?["phase"] as? String == "pre_input_rejection" ? "rejection" : "after"
        }
        facts["outcome"] = response["outcome"]
        if let code = (response["error"] as? [String: Any])?["code"] as? String {
            facts["errorCode"] = code.range(of: #"^[a-z][a-z0-9_]{0,79}\z"#, options: .regularExpression) != nil
                ? code : "backend_error"
        }
        facts["observationError"] = attached?["ok"] as? Bool == false
        facts["transportStatus"] = result["transportStatus"] as? String
        facts["verificationStatus"] = result["verificationStatus"] as? String
        for key in ["x", "y", "fromX", "fromY", "toX", "toY"] { facts[key] = request[key] as? NSNumber }
        facts["textLength"] = (request["text"] as? String)?.count
        let metadata = entry?.capture.metadata ?? [:]
        facts["axStatus"] = metadata["axStatus"] as? String
        facts["stable"] = (metadata["postActionStability"] as? [String: Any])?["stable"] as? Bool
        let level = eventLevel(facts, result: result)
        persist(facts, level: level, diagnostics: diagnostics, entry: entry, guardPNG: guardPNG)
    }

    private func persist(_ record: [String: Any], level: DiagnosticLevel, diagnostics: SessionDiagnostics,
                         entry: ObservationCache.Entry?, guardPNG: Data?) {
        var facts = record
        do {
            try diagnostics.database.transaction {
                try saveEvidence(&facts, entry: entry, guardPNG: guardPNG, diagnostics: diagnostics)
                try diagnostics.event(facts, level: level)
                if diagnostics.preferences.level == .debug {
                    try diagnostics.event(debugFacts(entry?.capture.metadata ?? [:]), level: .debug)
                }
            }
        } catch {
            response["eventRecordingError"] = "diagnostics_storage_error"
            facts["observationSaved"] = false
            facts.removeValue(forKey: "guardFrame")
            facts["diagnosticError"] = "diagnostics_storage_error"
            try? diagnostics.event(facts, level: .error)
        }
    }

    private func attachActionIdentity(to result: inout [String: Any], source: String?) {
        guard operation != "observe" else { return }
        result["actionID"] = id
        result["sourceObservationID"] = source
        response["result"] = result
    }

    private func eventLevel(_ facts: [String: Any], result: [String: Any]) -> DiagnosticLevel {
        if facts["axStatus"] as? String == "unavailable" || facts["observationError"] as? Bool == true
            || response["outcome"] as? String == "not_dispatched" { return .warn }
        if response["ok"] as? Bool == false && result["transportStatus"] as? String != "sent" { return .error }
        return .info
    }

    private func saveEvidence(_ facts: inout [String: Any], entry: ObservationCache.Entry?, guardPNG: Data?,
                              diagnostics: SessionDiagnostics) throws {
        let observedID = entry?.id
        guard let eventID = facts["requestID"] as? String else { return }
        facts["evidenceEnabled"] = diagnostics.preferences.captureEvidence
        if diagnostics.preferences.captureEvidence {
            facts["guardFrameAcquired"] = guardPNG != nil
            if let entry {
                facts["observationSaved"] = try retain(entry, diagnostics: diagnostics)
            }
            if let guardPNG, facts["observationRole"] as? String == "rejection",
               entry?.capture.screenshot == guardPNG {
                if facts["observationSaved"] as? Bool == true { facts["guardFrame"] = observedID }
            } else if let guardPNG {
                let key = "guard-" + eventID
                if try diagnostics.frame(key, png: guardPNG, snapshotData: nil, keeping: observedID) {
                    facts["guardFrame"] = key
                }
            }
        }
        if facts["observationSaved"] as? Bool == true || facts["guardFrame"] != nil {
            let links = facts.filter {
                ["operation", "requestID", "sourceObservation", "observation", "observationRole", "guardFrame",
                 "followingAction"].contains($0.key)
            }
            try diagnostics.database.execute(
                "UPDATE frames SET context=? WHERE session=? AND ref IN (?,?)",
                [.bytes(try jsonData(links)), .text(diagnostics.session), observedID.map { .text($0) } ?? .null,
                 (facts["guardFrame"] as? String).map { .text($0) } ?? .null])
        }
    }

    private func retain(_ entry: ObservationCache.Entry, diagnostics: SessionDiagnostics) throws -> Bool {
        let capture = entry.capture
        var snapshotData: Data?
        if !capture.nodes.isEmpty || capture.metadata["axStatus"] as? String == "available" {
            let nodes = capture.nodes.map { node -> [String: Any] in
                var values = node.attributes
                values["ref"] = node.ref
                values["role"] = node.role
                values["parentIndex"] = node.parent
                return values
            }
            var snapshot: [String: Any] = ["observation": entry.id, "nodes": nodes]
            let attached = response["observation"] as? [String: Any]
            let returned = (operation == "observe" ? response : attached)?["result"] as? [String: Any]
            if let text = returned?["text"] as? String, text.hasPrefix("obs="),
               let footer = text.range(of: "\nscreenshot=", options: .backwards) {
                snapshot["compact"] = String(text[..<footer.lowerBound])
            }
            for key in ["screenFrame", "displayRotation", "axStatus", "sourceTruncated",
                        "snapshotStartedAt", "snapshotFinishedAt",
                        "screenshotCapturedAt", "observationAcquisition"] { snapshot[key] = capture.metadata[key] }
            snapshotData = try jsonData(snapshot)
        }
        return try diagnostics.frame(entry.id, png: capture.screenshot, snapshotData: snapshotData)
    }

    private func debugFacts(_ metadata: [String: Any]) -> [String: Any] {
        let result = response["result"] as? [String: Any] ?? [:]
        var facts: [String: Any] = ["operation": "timings", "requestID": diagnosticID]
        let stability = metadata["postActionStability"] as? [String: Any]
        facts["samples"] = stability?["samples"] as? Int
        facts["settlingMs"] = stability?["elapsedMs"] as? Double
        facts["preInputCaptures"] = result["preInputCaptures"] as? Int
        let checks = result["preInputChecks"] as? [[String: Any]]
        facts["preInputSampleMs"] = checks?.compactMap { $0["elapsedMs"] as? Double }
        let acquisition = metadata["observationAcquisition"] as? [String: Any]
        for name in ["ax", "screenshot"] {
            if let interval = acquisition?[name] as? [String: Any], let start = interval["startedAt"] as? Double,
               let finish = interval["finishedAt"] as? Double { facts[name + "Ms"] = (finish - start) * 1000 }
        }
        let collection = metadata["axCollection"] as? [String: Any]
        for key in ["stageTimingsMs", "collectionTimingsMs"] {
            facts[key] = collection?[key] as? [String: Double]
        }
        return facts
    }
}
