import XCTest
@testable import Omodachi

/// Production workspace immutable offer / Encodable wire body / result policy:
/// stable scope heartbeat acceptance, captured global revision, away/back/restart
/// rejection, no downgrade on null/invalid, legacy strictness, same-ID cached
/// retry, explicit enum, no focus token, partial/stale outcomes. Synthetic only.
final class WorkspaceLayoutActionTests: XCTestCase {
    private func offer(workspace: Int? = 7, revision: Int = 12, connection: UUID = UUID(),
                       bindingPresent: Bool = false, binding: WorkspaceLayoutBinding? = nil,
                       reason: String? = "workspace_layout_dwindle", status: String? = "available",
                       visible: Bool = true, ready: Bool = true, supported: Bool = true,
                       null: Bool = true, route: String? = "host") -> WorkspaceLayoutOffer? {
        .init(connection: connection, workspaceID: workspace, stateRevision: revision, catalogRevision: "catalog-snapshot-12",
              visible: visible, supported: supported, ready: ready, route: route, checkedStatus: status,
              checkedReason: reason, checkedValueIsNull: null, bindingFieldPresent: bindingPresent, binding: binding)
    }
    private func effects(_ request: WorkspaceLayoutRequest, runtime: Bool = true, persisted: Bool = true,
                         readback: Bool = true, status: String = "applied", workspace: Int? = nil,
                         code: String = "workspace_layout_applied") throws -> WorkspaceLayoutEffects {
        let body: [String: Any] = ["workspace_id": workspace ?? request.params.workspaceID,
            "from_layout": request.params.fromLayout.rawValue, "layout": request.params.layout.rawValue,
            "runtime_applied": runtime, "persistent_applied": persisted, "readback_confirmed": readback,
            "status": status, "code": code]
        return try JSONDecoder().decode(WorkspaceLayoutEffects.self, from: JSONSerialization.data(withJSONObject: body))
    }

    func testCheckedConditionDecoding() throws {
        let condition = try JSONDecoder().decode(CatalogCheckedConditionDTO.self, from: Data(#"{"status":"available","value":null,"reason":"workspace_layout_dwindle"}"#.utf8))
        XCTAssertTrue(condition.valueIsNull)
        XCTAssertEqual(condition.status, "available")
        XCTAssertEqual(condition.reason, "workspace_layout_dwindle")
        let missingValue = try JSONDecoder().decode(CatalogCheckedConditionDTO.self, from: Data(#"{"status":"available","reason":"workspace_layout_dwindle"}"#.utf8))
        XCTAssertFalse(missingValue.valueIsNull)
        let booleanValue = try JSONDecoder().decode(CatalogCheckedConditionDTO.self, from: Data(#"{"status":"available","value":false,"reason":"workspace_layout_dwindle"}"#.utf8))
        XCTAssertFalse(booleanValue.valueIsNull)
        XCTAssertThrowsError(try JSONDecoder().decode(CatalogCheckedConditionDTO.self, from: Data(#"{"status":"available","value":"invalid","reason":"workspace_layout_dwindle"}"#.utf8))) { error in
            XCTAssertTrue(error is DecodingError, "Invalid condition value decoded")
        }
    }

    func testScopedBindingHeartbeatAcceptanceAndRejection() throws {
        let stableJSON = #"{"workspace_id":7,"layout":"dwindle","revision":9,"instance_id":"bfcf4993-0bd3-471e-bc90-104a779c59e7"}"#
        let scoped = try JSONDecoder().decode(WorkspaceLayoutBinding.self, from: Data(stableJSON.utf8))
        let connection = UUID()
        let stableOffer = try XCTUnwrap(offer(revision: 353, connection: connection, bindingPresent: true, binding: scoped))
        let stableSelection = try stableOffer.selection()
        let heartbeat = try XCTUnwrap(offer(revision: 354, connection: connection, bindingPresent: true, binding: scoped))
        XCTAssertTrue(stableSelection.matchesCurrent(heartbeat))
        XCTAssertEqual(stableSelection.request.stateRevision, 353, "captured revision is NOT silently updated")
        let stableBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(stableSelection.request)) as? [String: Any])
        XCTAssertEqual(Set(stableBody.keys), ["request_id", "catalog_revision", "state_revision", "params", "workspace_binding"])
        let bindingBody = try XCTUnwrap(stableBody["workspace_binding"] as? [String: Any])
        XCTAssertEqual(Set(bindingBody.keys), ["revision", "instance_id"])
        XCTAssertEqual(bindingBody["revision"] as? Int, 9)
        XCTAssertNil(stableBody["target_token"])
        let awayBack = try JSONDecoder().decode(WorkspaceLayoutBinding.self, from: Data(stableJSON.replacingOccurrences(of: "\"revision\":9", with: "\"revision\":11").utf8))
        XCTAssertFalse(stableSelection.matchesCurrent(offer(revision: 355, connection: connection, bindingPresent: true, binding: awayBack)))
        let restarted = try JSONDecoder().decode(WorkspaceLayoutBinding.self, from: Data(stableJSON.replacingOccurrences(of: scoped.instanceID, with: UUID().uuidString).utf8))
        XCTAssertFalse(stableSelection.matchesCurrent(offer(revision: 354, connection: connection, bindingPresent: true, binding: restarted)))
        XCTAssertFalse(stableSelection.matchesCurrent(nil))
        XCTAssertNil(offer(revision: 354, connection: connection, bindingPresent: true, binding: nil))
        XCTAssertNil(offer(workspace: 8, connection: connection, bindingPresent: true, binding: scoped))
        XCTAssertNil(offer(connection: connection, bindingPresent: true, binding: scoped, reason: "workspace_layout_scrolling"))
        let legacySelection = try XCTUnwrap(offer(connection: connection)).selection()
        XCTAssertFalse(legacySelection.matchesCurrent(offer(revision: 13, connection: connection)))
        XCTAssertFalse(legacySelection.matchesCurrent(offer(connection: connection, bindingPresent: true, binding: scoped)))
        // An explicit unknown-result retry can retrieve the original cached
        // receipt even if its own success changed the current layout epoch.
        XCTAssertTrue(stableSelection.canRetrySameRequest(connection: connection, serverInstanceID: scoped.instanceID))
        XCTAssertFalse(stableSelection.canRetrySameRequest(connection: UUID(), serverInstanceID: scoped.instanceID))
        XCTAssertFalse(stableSelection.canRetrySameRequest(connection: connection, serverInstanceID: restarted.instanceID))
        XCTAssertFalse(legacySelection.canRetrySameRequest(connection: connection, serverInstanceID: scoped.instanceID))
        for malformed in [stableJSON.replacingOccurrences(of: "\"revision\":9", with: "\"revision\":0"),
                          stableJSON.replacingOccurrences(of: "\"revision\":9", with: "\"revision\":true"),
                          stableJSON.replacingOccurrences(of: "dwindle", with: "unknown"),
                          stableJSON.replacingOccurrences(of: scoped.instanceID, with: "")] {
            XCTAssertThrowsError(try JSONDecoder().decode(WorkspaceLayoutBinding.self, from: Data(malformed.utf8)), "Invalid binding accepted")
        }
        XCTAssertEqual(WorkspaceLayoutRequestError.safeCode("stale_workspace_binding"), "stale_workspace_binding")
        XCTAssertEqual(WorkspaceLayoutRequestError.safeCode("invalid_workspace_binding"), "invalid_workspace_binding")
    }

    func testImmutableOfferAndWireBody() throws {
        let displayed = try XCTUnwrap(offer())
        let selection = try displayed.selection()
        let request = selection.request
        let first = try JSONEncoder().encode(request)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["request_id", "catalog_revision", "state_revision", "params"])
        XCTAssertNil(body["target_token"])
        XCTAssertEqual(body["state_revision"] as? Int, 12)
        XCTAssertEqual(body["request_id"] as? String, selection.id)
        let params = try XCTUnwrap(body["params"] as? [String: Any])
        XCTAssertEqual(Set(params.keys), ["workspace_id", "from_layout", "layout"])
        XCTAssertEqual(params["workspace_id"] as? Int, 7)
        XCTAssertEqual(params["from_layout"] as? String, "dwindle")
        XCTAssertEqual(params["layout"] as? String, "scrolling")
        // Display can change while the user's confirmation stays open. Neither
        // that new workspace nor a focused-window token exists in the capture.
        let newer = try XCTUnwrap(offer(workspace: 2, revision: 99, reason: "workspace_layout_scrolling"))
        XCTAssertNotEqual(newer.workspaceID, selection.request.params.workspaceID)
        let repeated = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(selection.request)) as? NSDictionary)
        XCTAssertTrue(repeated.isEqual(to: body))
        XCTAssertEqual(selection.request.stateRevision, 12)
        XCTAssertEqual(selection.request.catalogRevision, "catalog-snapshot-12")
        for invalid in [offer(workspace: nil), offer(workspace: 0), offer(workspace: 11), offer(revision: -1),
                        offer(reason: nil), offer(reason: "unknown"), offer(status: "unavailable"), offer(visible: false),
                        offer(ready: false), offer(supported: false), offer(null: false), offer(route: "terminal")] {
            XCTAssertNil(invalid)
        }
        let emptyWorkspaceSelection = try XCTUnwrap(offer(workspace: 10, reason: "workspace_layout_scrolling")).selection()
        XCTAssertEqual(emptyWorkspaceSelection.request.params.layout, .dwindle)
        for from in [WorkspaceLayout.dwindle, .scrolling] {
            XCTAssertThrowsError(try WorkspaceLayoutRequest(workspaceID: 1, fromLayout: from, target: from, stateRevision: 1, catalogRevision: "c"), "same layout accepted") { error in
                XCTAssertTrue(error is WorkspaceLayoutRequestError)
            }
        }
    }

    func testResultPolicyOutcomes() throws {
        let displayed = try XCTUnwrap(offer())
        let request = try displayed.selection().request
        let applied = try effects(request)
        let success = WorkspaceLayoutResultPolicy.message(request: request, responseRequestID: request.requestID, entryID: WorkspaceLayoutRequest.entryID, status: "accepted", effects: applied)
        XCTAssertEqual(success, Strings.workspaceLayoutConfirmed(Format.count(applied.workspaceID), applied.layout.label))
        XCTAssertFalse(success.contains(Strings.workspaceRuntimeUnconfirmed))
        let partial = try effects(request, persisted: false, status: "partial", code: "workspace_layout_persistence_conflict_preserved")
        let partialText = WorkspaceLayoutResultPolicy.message(request: request, responseRequestID: request.requestID, entryID: WorkspaceLayoutRequest.entryID, status: "failed", effects: partial)
        XCTAssertTrue(partialText.contains(Strings.workspacePersistedUnconfirmed))
        XCTAssertTrue(partialText.contains(ReasonText.message("existing_file_conflict", domain: .workspace)))
        XCTAssertTrue(partialText.contains(Strings.workspaceReadbackConfirmed) || partialText.contains(Strings.workspaceReadbackUnconfirmed))
        for flag in 0..<3 {
            let unconfirmed = try effects(request, runtime: flag != 0, persisted: flag != 1, readback: flag != 2)
            let text = WorkspaceLayoutResultPolicy.message(request: request, responseRequestID: request.requestID, entryID: WorkspaceLayoutRequest.entryID, status: "accepted", effects: unconfirmed)
            XCTAssertNotEqual(text, Strings.workspaceLayoutConfirmed(Format.count(unconfirmed.workspaceID), unconfirmed.layout.label))
        }
        let wrong = try effects(request, workspace: 2)
        for (id, entry, effect) in [("another-id", WorkspaceLayoutRequest.entryID, applied),
                                    (request.requestID, "other-entry", applied),
                                    (request.requestID, WorkspaceLayoutRequest.entryID, wrong)] {
            let text = WorkspaceLayoutResultPolicy.message(request: request, responseRequestID: id, entryID: entry, status: "accepted", effects: effect)
            XCTAssertEqual(text, ReasonText.message("workspace_layout_outcome_unknown", domain: .workspace))
        }
        let unknown = WorkspaceLayoutResultPolicy.message(request: request, responseRequestID: request.requestID, entryID: WorkspaceLayoutRequest.entryID, status: "failed", effects: nil)
        XCTAssertEqual(unknown, ReasonText.message("workspace_layout_outcome_unknown", domain: .workspace))
        for code in ["stale_workspace_revision", "stale_workspace", "workspace_layout_changed", "stale_catalog_revision"] {
            XCTAssertEqual(WorkspaceLayoutRequestError(code: code).message, ReasonText.message("stale_plan", domain: .workspace))
            XCTAssertEqual(WorkspaceLayoutRequestError.safeCode(code), code)
        }
        XCTAssertEqual(WorkspaceLayoutRequestError.safeCode("workspace_layout_persistence_conflict_preserved"), "workspace_layout_persistence_conflict_preserved")
        XCTAssertEqual(WorkspaceLayoutRequestError.safeCode("untrusted arbitrary server text"), "workspace_layout_outcome_unknown")
    }
}
