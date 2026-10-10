import Foundation

/// Core speaks in codes; this is where a code becomes a sentence in the
/// reader's language (I18N-1 §2).
///
/// Before this file the app had eight private `userMessage` switches, each
/// written in whichever language the author of that file happened to be in.
/// On a Chinese iPad that produced exactly what Leo saw: a Chinese panel that
/// says `The agent session changed…` under one tap and `主机上已经有一个会话。`
/// under the next. Every one of those switches now ends here, and every arm is
/// a catalog key with both languages filled in.
///
/// Three rules hold:
///
/// * **A code never reaches the screen on its own.** `unknown(_:domain:)` is
///   the only place a code is shown, and it is shown *beside* a sentence, in
///   brackets, so a reason nobody mapped is still reportable.
/// * **The host's own words are not in here.** A menu row, a keybinding name,
///   a notification body and an agent's reply arrive from the machine and are
///   drawn verbatim (ARCH-1 §6).
/// * **`knownCodes` is the contract's whole set.** `scripts/check_xcstrings.py`
///   reads `omodachi-core/contracts` and fails the build when core names a
///   reason this file does not, and `ReasonTextTests` walks the same list in
///   both languages.
enum ReasonText {
    /// Which half of the API raised the code. Four codes — `permission_denied`,
    /// `pairing_required`, `session_not_found`, `timeout` — mean different
    /// things to Remote and to the pairing bridge, so the domain picks first
    /// and `shared` only answers what is the same everywhere.
    enum Domain: String, CaseIterable, Sendable {
        case remote, media, herdr, voice, agent, workspace, host
    }

    // MARK: - Entry point

    /// `status` is the HTTP status when there was one; `503` reads as "that
    /// part of the host is not up yet" rather than as a refusal.
    static func message(_ code: String, domain: Domain, status: Int = 0) -> String {
        if let text = domainText(code, domain: domain) { return text }
        if let text = shared(code) { return text }
        return unknown(code, domain: domain, status: status)
    }

    // MARK: - Per domain

    private static func domainText(_ code: String, domain: Domain) -> String? {
        switch domain {
        case .remote: remote(code)
        case .media: media(code)
        case .herdr: herdr(code)
        case .voice: voice(code)
        case .agent: agent(code)
        case .workspace: workspace(code)
        case .host: nil
        }
    }

    static func remote(_ code: String) -> String? {
        switch code {
        case "remote_session_exists": Strings.reasonRemoteSessionExists
        case "stale_revision": Strings.reasonStaleRevision
        case "session_not_found": Strings.reasonSessionNotFound
        // REMOTE-STOP-1 §3 / STORE-6 §B2: the person at the computer ended it
        // (`omodachi-host remote stop`, or the panel's End Remote session).
        // It is an ending, not a failure, and it says who ended it.
        case "ended_on_computer": Strings.reasonEndedOnComputer
        case "session_not_ready": Strings.reasonSessionNotReady
        case "permission_denied": Strings.reasonRemotePermissionDenied
        case "media_pairing_required": Strings.reasonMediaPairingRequired
        case "wayvnc_0_10_1_required": Strings.reasonWayvncRequired
        case "sunshine_desktop_unavailable": Strings.reasonSunshineDesktopUnavailable
        case "sunshine_control_unavailable": Strings.reasonSunshineControlUnavailable
        case "backend_not_installed": Strings.reasonBackendNotInstalled
        case "sunshine_assets_missing": Strings.reasonSunshineAssetsMissing
        // TAIL-2 P2-2: `capabilities.road.reason`, the path is a DERP relay.
        case "tailnet_relayed": Strings.remoteTailnetRelayed
        case "remote_runtime_unavailable": Strings.reasonRemoteRuntimeUnavailable
        case "dynamic_resolution_policy_denied": Strings.reasonDynamicResolutionDenied
        case "host_waking": Strings.reasonHostWaking
        case "vnc_bridge_unavailable": Strings.reasonVncBridgeUnavailable
        case "vnc_bridge_exists": Strings.reasonVncBridgeExists
        // REMOTE-INPUT-1: `POST /v1/remote/sessions/{id}/text`.
        case "remote_text_unavailable": Strings.remoteTypingUnavailable
        case "remote_text_failed": Strings.remoteTypingFailed
        case "viewport_aspect_unsupported", "density_profile_unsupported", "quality_profile_unsupported":
            Strings.reasonProfileUnsupported
        case "pairing_required", "invalid_request": Strings.reasonRemoteRefused
        case "remote_session_required": Strings.reasonRemoteSessionRequired
        case "invalid_workspace_request": Strings.reasonInvalidWorkspaceRequest
        case "invalid_output", "display_output_limit", "output_limit": Strings.reasonDisplayOutputLimit
        case "display_asleep": Strings.reasonDisplayAsleep
        case "display_timeout", "display_command_failed": Strings.reasonDisplayCommandFailed
        case "resize_failed": Strings.reasonResizeFailed
        case "release_failed": Strings.reasonReleaseFailed
        case "expired_awaiting_sunshine_cleanup": Strings.reasonExpiredAwaitingCleanup
        case "sunshine_certificate_revocation_unavailable": Strings.reasonSunshineRevocationUnavailable
        case "sunshine_unit_unreadable": Strings.reasonSunshineUnitUnreadable
        case "disabled_output_left_for_operator": Strings.reasonDisabledOutputLeft
        default: nil
        }
    }

    static func media(_ code: String) -> String? {
        switch code {
        case "media_pairing_unavailable": Strings.reasonMediaPairingUnavailable
        case "media_pairing_request_not_unique": Strings.reasonMediaRequestNotUnique
        case "media_pairing_request_not_pending": Strings.reasonMediaRequestNotPending
        case "media_certificate_already_associated": Strings.reasonMediaCertificateAssociated
        case "media_pairing_binding_mismatch": Strings.reasonMediaBindingMismatch
        case "media_permission_required", "media_permission_not_explicit": Strings.reasonMediaPermissionRequired
        case "media_pairing_invalid_pin": Strings.reasonMediaInvalidPin
        case "media_pairing_capacity": Strings.reasonMediaCapacity
        case "media_pairing_not_found": Strings.reasonMediaNotFound
        case "media_pairing_timeout": Strings.reasonMediaTimeout
        case "permission_denied", "pairing_required": Strings.reasonMediaRefused
        case "pin_resubmission_required": Strings.reasonMediaPinSpent
        case "media_grant_revoked": Strings.reasonMediaGrantRevoked
        case "media_revocation_pending": Strings.reasonMediaRevocationPending
        case "media_pairing_state_unavailable": Strings.reasonMediaStateUnavailable
        default: nil
        }
    }

    static func herdr(_ code: String) -> String? {
        switch code {
        case "herdr_control_in_use": Strings.reasonHerdrControlInUse
        // ATTACH-1: a chip whose file is no longer on the computer
        case "attachment_gone": Strings.attachGone
        case "herdr_unavailable": Strings.reasonHerdrUnavailable
        case "herdr_request_failed": Strings.reasonHerdrRequestFailed
        case "invalid_pane": Strings.reasonInvalidPane
        case "invalid_workspace": Strings.reasonInvalidWorkspace
        case "invalid_geometry": Strings.reasonInvalidGeometry
        case "herdr_action_unsupported": Strings.reasonHerdrActionUnsupported
        // HERDR-3: keys and text
        case "invalid_key": Strings.reasonInvalidKey
        case "herdr_key_unsupported": Strings.reasonHerdrKeyUnsupported
        case "herdr_too_many_keys": Strings.reasonHerdrTooManyKeys
        case "invalid_text": Strings.reasonInvalidText
        case "herdr_text_too_long": Strings.reasonHerdrTextTooLong
        case "herdr_pane_gone": Strings.reasonHerdrPaneGone
        // `/text`'s `reason`, when the text went in and Enter did not follow
        case "not_seen": Strings.reasonHerdrNotSeen
        case "submit_failed": Strings.reasonHerdrSubmitFailed
        case "not_requested": Strings.reasonHerdrNotRequested
        // VERIFY-1: a dialog has the keyboard, so nothing was typed
        case "herdr_agent_blocked": Strings.reasonHerdrAgentBlocked
        // HERDR-5: starting and making sessions
        case "invalid_session": Strings.reasonInvalidSession
        case "invalid_session_name": Strings.reasonInvalidSessionName
        case "herdr_session_exists": Strings.reasonHerdrSessionExists
        case "herdr_session_start_failed": Strings.reasonHerdrSessionStartFailed
        // HERDR-6: a new workspace in a folder
        case "invalid_folder": Strings.reasonInvalidFolder
        case "folder_outside_home": Strings.reasonFolderOutsideHome
        case "folder_private": Strings.reasonFolderPrivate
        case "folder_not_found": Strings.reasonFolderNotFound
        case "folder_unreadable": Strings.reasonFolderUnreadable
        case "invalid_workspace_name": Strings.reasonInvalidWorkspaceName
        // HERDR-11: a launcher the host no longer lists
        case "herdr_launch_not_allowed": Strings.reasonHerdrLaunchNotAllowed
        default: nil
        }
    }

    static func voice(_ code: String) -> String? {
        switch code {
        case "voxtype_not_installed": Strings.reasonVoxtypeNotInstalled
        case "voice_uplink_disabled": Strings.reasonVoiceUplinkDisabled
        case "audio_input_busy": Strings.reasonAudioInputBusy
        case "audio_input_unsupported", "audio_input_unavailable": Strings.reasonAudioInputUnavailable
        case "audio_backend_not_installed": Strings.reasonAudioBackendNotInstalled
        case "audio_backend_unavailable": Strings.reasonAudioBackendUnavailable
        case "audio_input_cleanup_pending": Strings.reasonAudioCleanupPending
        case "audio_input_backpressure": Strings.reasonAudioBackpressure
        case "voxtype_wait_unsupported": Strings.reasonVoxtypeWaitUnsupported
        case "voxtype_config_unsupported": Strings.reasonVoxtypeConfigUnsupported
        case "voxtype_service_inactive": Strings.reasonVoxtypeServiceInactive
        case "microphone_permission_denied": Strings.reasonMicrophonePermissionDenied
        case "route_changed": Strings.reasonRouteChanged
        case "interrupted": Strings.reasonInterrupted
        case "audio_session_error", "input_unavailable": Strings.reasonAudioSessionError
        case "conversion_failed": Strings.reasonConversionFailed
        case "transport_closed", "backend_closed", "stream_closed": Strings.reasonTransportClosed
        case "host_unavailable", "voice_unavailable": Strings.reasonVoiceHostUnavailable
        case "user_disabled": Strings.reasonVoiceUserDisabled
        case "session_end": Strings.reasonVoiceSessionEnd
        case "disconnected": Strings.reasonVoiceDisconnected
        case "ready": Strings.reasonVoiceReady
        default: nil
        }
    }

    static func agent(_ code: String) -> String? {
        switch code {
        case "attachment_gone": Strings.attachGone
        case "existing_thread_handoff_required": Strings.reasonHandoffRequired
        case "agent_busy", "agent_pane_busy": Strings.reasonAgentBusy
        case "handoff_rolled_back": Strings.reasonHandoffRolledBack
        case "handoff_plan_expired", "handoff_target_changed": Strings.reasonHandoffStale
        case "handoff_stop_unconfirmed", "handoff_attach_unconfirmed", "handoff_thread_unconfirmed":
            Strings.reasonHandoffUnconfirmed
        case "handoff_transport_unavailable": Strings.reasonHandoffTransportUnavailable
        case "agent_owner_start_failed", "agent_owner_start_timeout", "agent_owner_socket_unavailable",
             "thread_creation_unconfirmed", "provider_request_rejected", "structured_agent_kind_unsupported",
             "agent_state_unknown":
            Strings.reasonAgentStartFailed
        case "agent_blocked": Strings.reasonAgentBlocked
        case "agent_not_working": Strings.reasonAgentNotWorking
        case "agent_kind_mismatch": Strings.reasonAgentKindMismatch
        case "agent_kind_unsupported": Strings.reasonAgentKindUnsupported
        case "agent_chat_unavailable": Strings.reasonAgentChatUnavailable
        // AGENT-NEW-1
        case "agent_turn_active": Strings.agentNewWhileWorking
        case "agent_approval_pending": Strings.agentNewWhileWaiting
        case "agent_identity_changed": Strings.reasonAgentReplaced
        case "agent_conversation_changing": Strings.reasonAgentChanging
        case "new_conversation_confirmation_required": Strings.reasonAgentNewConfirm
        case "agent_thread_creation_unconfirmed": Strings.reasonAgentNewUnconfirmed
        // AGENT-PLAN-1
        case "agent_mode_unavailable": Strings.reasonAgentModeUnavailable
        case "invalid_agent_mode": Strings.reasonAgentModeInvalid
        case "agent_command_while_working": Strings.reasonAgentCommandWhileWorking
        // agent-chat-commands.schema.json, for older Apps: this one never
        // asks that route, so one sentence says it for all four.
        case "command_terminal_only", "command_settings_on_computer", "command_sessions_on_computer",
             "command_not_on_phone_yet":
            Strings.reasonAgentCommandOnComputer
        case "agent_approval_unknown": Strings.reasonAgentApprovalUnknown
        case "agent_approval_changed": Strings.reasonAgentApprovalChanged
        case "agent_approval_decision_invalid": Strings.reasonAgentApprovalInvalid
        case "agent_cli_rejected": Strings.reasonAgentCliRejected
        case "default_agent_unset": Strings.reasonDefaultAgentUnset
        case "default_agent_exists": Strings.reasonDefaultAgentExists
        case "provider_adapter_failed", "provider_adapter_unavailable": Strings.reasonProviderAdapterUnavailable
        case "provider_thread_not_loaded", "provider_thread_not_materialized", "provider_thread_rollout_missing":
            Strings.reasonProviderThreadMissing
        case "unmaterialized_empty_session_lost_after_host_restart": Strings.reasonAgentSessionLost
        case "task_too_large": Strings.reasonTaskTooLarge
        case "empty_task": Strings.reasonEmptyTask
        case "history_unavailable": Strings.reasonHistoryUnavailable
        case "cancellation_pending": Strings.reasonCancellationPending
        default: nil
        }
    }

    static func workspace(_ code: String) -> String? {
        switch code {
        case "workspace_layout_applied": Strings.reasonWorkspaceLayoutApplied
        case "workspace_layout_failed", "workspace_layout_command_failed": Strings.reasonWorkspaceLayoutFailed
        case "workspace_layout_outcome_unknown": Strings.reasonWorkspaceOutcomeUnknown
        case "workspace_preflight_unavailable": Strings.reasonWorkspacePreflightUnavailable
        case "invalid_workspace_request": Strings.reasonInvalidWorkspaceRequest
        case "stale_plan": Strings.reasonStalePlan
        case "stale_revision": Strings.reasonStaleRevision
        case "existing_file_conflict": Strings.reasonExistingFileConflict
        case "no_focused_window": Strings.reasonNoFocusedWindow
        case "no_backup": Strings.reasonNoBackup
        case "newer_than_cutoff": Strings.reasonNewerThanCutoff
        default: nil
        }
    }

    /// The codes that mean one thing wherever they come from.
    static func shared(_ code: String) -> String? {
        switch code {
        case "daemon_unavailable", "daemon_restarted": Strings.reasonDaemonUnavailable
        case "live_state_unavailable", "state_adapter_failed", "state_adapter_source_changed":
            Strings.reasonLiveStateUnavailable
        case "route_state_unavailable", "route_unavailable": Strings.reasonRouteUnavailable
        case "theme_unavailable": Strings.reasonThemeUnavailable
        case "fonts_unavailable", "font_not_found": Strings.reasonFontsUnavailable
        case "icon_not_found": Strings.reasonIconNotFound
        case "notifications_unavailable": Strings.reasonNotificationsUnavailable
        case "apps_reader_unavailable", "reader_failed", "reader_missing": Strings.reasonAppsReaderUnavailable
        case "herdr_unavailable": Strings.reasonHerdrUnavailable
        case "stale_catalog_revision", "menu_source_changed", "menu_action_changed", "menu_surface_changed":
            Strings.reasonStaleCatalogRevision
        case "binding_adapter_unavailable": Strings.reasonBindingAdapterUnavailable
        // CLIP-1. The two 403s are the switches, not a credential: a person
        // told "not authorised" would go and re-pair a device that is fine.
        case "clipboard_sync_disabled": Strings.reasonClipboardSyncDisabled
        case "clipboard_write_disabled": Strings.reasonClipboardWriteDisabled
        case "clipboard_too_large": Strings.reasonClipboardTooLarge
        case "clipboard_not_text": Strings.reasonClipboardNotText
        case "clipboard_invalid": Strings.reasonClipboardInvalid
        case "clipboard_unavailable": Strings.reasonClipboardUnavailable
        case "condition_adapter_failed", "condition_adapter_unavailable", "condition_shape_unsupported":
            Strings.reasonConditionUnavailable
        // MENU-3. `condition_disabled` is a row the host greys on purpose;
        // the other three ride on an `unknown` reading, whose row stays usable.
        case "condition_disabled": Strings.reasonConditionDisabled
        case "condition_timeout": Strings.reasonConditionTimeout
        case "condition_spawn_failed": Strings.reasonConditionSpawnFailed
        case "condition_pending": Strings.reasonConditionPending
        case "executable_missing", "invalid_command": Strings.reasonExecutableMissing
        // MENU-4. The first two are a grey row's reason, said on the row; the
        // last is a run the host could not start.
        case "menu_action_needs_terminal": Strings.reasonMenuActionNeedsTerminal
        case "menu_action_empty": Strings.reasonMenuActionEmpty
        case "menu_row_not_invocable": Strings.reasonMenuRowNotInvocable
        case "graphical_session_unavailable": Strings.reasonGraphicalSessionUnavailable
        case "execution_failed", "action_failed", "runner_failed", "control_request_failed", "control_failure":
            Strings.reasonExecutionFailed
        case "setup_required", "polkit_not_configured", "pam_root_required": Strings.reasonSetupRequired
        case "credential_registry_unavailable", "authorized_keys_unreadable": Strings.reasonCredentialRegistryUnavailable
        // CORE-2 §1: the four refusals a 401 now names, and the renewal's two.
        case "credential_expired": Strings.reasonCredentialExpired
        case "credential_revoked": Strings.reasonCredentialRevoked
        case "device_purged": Strings.reasonDevicePurged
        case "unknown_credential": Strings.reasonUnknownCredential
        case "credential_renewal_not_due": Strings.reasonCredentialRenewalNotDue
        case "plugin_credential": Strings.reasonPluginCredential
        // REMOTE-PAIR-1: the host could not check credentials just now (503).
        case "auth_unavailable": Strings.reasonAuthUnavailable
        case "discovery_integration_failed", "discovery_registration_failed": Strings.reasonDiscoveryUnavailable
        case "desktop_entry_unavailable", "desktop_entry_install_failed": Strings.reasonDesktopEntryUnavailable
        case "preferences_invalid": Strings.reasonPreferencesInvalid
        case "socket_not_in_shared_runtime_root": Strings.reasonSocketNotShared
        case "queue_overflow": Strings.reasonQueueOverflow
        case "approval_outcome_unknown": Strings.reasonApprovalOutcomeUnknown
        case "already_authorized": Strings.reasonAlreadyAuthorized
        // UX-4: `PUT /v1/ssh/key` reports which of the three happened. All
        // three are outcomes rather than failures, so all three say what the
        // host now holds.
        case "added": Strings.reasonSshKeyAdded
        case "replaced": Strings.reasonSshKeyReplaced
        case "session_not_found": Strings.reasonSessionNotFound
        case "permission_denied": Strings.reasonPermissionDenied
        case "timeout": Strings.reasonTimeout
        case "unavailable": Strings.reasonUnavailable
        case "rate_limited": Strings.reasonRateLimited
        // LINKS-1: `POST /v1/host/open`. Each refusal says what it was about
        // the file, never "not allowed", which would send someone to re-pair.
        case "open_not_mentioned": Strings.reasonOpenNotMentioned
        case "open_outside_roots": Strings.reasonOpenOutsideRoots
        case "open_denied": Strings.reasonOpenDenied
        case "open_executable": Strings.reasonOpenExecutable
        case "open_missing": Strings.reasonOpenMissing
        case "open_source_gone": Strings.reasonOpenSourceGone
        case "open_type_refused": Strings.reasonOpenTypeRefused
        case "open_url_refused": Strings.reasonOpenURLRefused
        case "open_rate_limited": Strings.reasonOpenRateLimited
        case "open_unavailable": Strings.reasonOpenUnavailable
        // Not core's code: the app's own, for a core from before LINKS-1.
        case "open_unsupported": Strings.reasonOpenUnsupported
        default: nil
        }
    }

    /// The one place a code is ever shown. A sentence first, the code in
    /// brackets after it, so an unmapped reason is still reportable.
    static func unknown(_ code: String, domain: Domain, status: Int = 0) -> String {
        if status == 503 {
            return Strings.reasonPartNotReady(code)
        }
        return switch domain {
        case .remote: Strings.reasonRemoteUnknown(code)
        case .media: Strings.reasonMediaUnknown(code)
        case .herdr: Strings.reasonHerdrUnknown(code)
        case .voice: Strings.reasonVoiceUnknown(code)
        case .agent: Strings.reasonAgentUnknown(code)
        case .workspace: Strings.reasonWorkspaceUnknown(code)
        case .host: Strings.reasonHostUnknown(code)
        }
    }

    // MARK: - The contract's set

    /// Every reason and error code `omodachi-core/contracts` names, as one
    /// list. `scripts/check_xcstrings.py --contracts <path>` regenerates the
    /// comparison from the schemas and `docs/remote-api.md`, so a code core
    /// adds and this file does not map fails the build rather than reaching a
    /// screen as a bare identifier.
    static let knownCodes: [String: Domain] = [
        // ATTACH-1
        "attachment_gone": .herdr,
        // remote-api.md §Errors, plus the two capability reasons beside it
        "remote_session_exists": .remote, "stale_revision": .remote, "session_not_found": .remote,
        "session_not_ready": .remote, "permission_denied": .remote, "media_pairing_required": .remote,
        "wayvnc_0_10_1_required": .remote, "sunshine_desktop_unavailable": .remote,
        "sunshine_assets_missing": .remote, "remote_runtime_unavailable": .remote,
        "tailnet_relayed": .remote,
        "dynamic_resolution_policy_denied": .remote, "host_waking": .remote,
        "vnc_bridge_unavailable": .remote, "vnc_bridge_exists": .remote,
        "remote_text_unavailable": .remote, "remote_text_failed": .remote,
        "sunshine_control_unavailable": .remote, "backend_not_installed": .remote,
        "viewport_aspect_unsupported": .remote, "density_profile_unsupported": .remote,
        "quality_profile_unsupported": .remote, "pairing_required": .remote, "invalid_request": .remote,
        "remote_session_required": .remote, "invalid_output": .remote, "display_output_limit": .remote,
        "output_limit": .remote, "display_asleep": .remote, "display_timeout": .remote,
        "display_command_failed": .remote, "resize_failed": .remote, "release_failed": .remote,
        "expired_awaiting_sunshine_cleanup": .remote,
        "sunshine_certificate_revocation_unavailable": .remote, "sunshine_unit_unreadable": .remote,
        "disabled_output_left_for_operator": .remote, "ended_on_computer": .remote,
        // the media-pairing bridge
        "media_pairing_unavailable": .media, "media_pairing_request_not_unique": .media,
        "media_pairing_request_not_pending": .media, "media_certificate_already_associated": .media,
        "media_pairing_binding_mismatch": .media, "media_permission_required": .media,
        "media_permission_not_explicit": .media, "media_pairing_invalid_pin": .media,
        "media_pairing_capacity": .media, "media_pairing_not_found": .media,
        "media_pairing_timeout": .media, "pin_resubmission_required": .media,
        "media_grant_revoked": .media, "media_revocation_pending": .media,
        "media_pairing_state_unavailable": .media,
        // herdr.md
        "herdr_control_in_use": .herdr, "herdr_unavailable": .herdr, "herdr_request_failed": .herdr,
        "invalid_pane": .herdr, "invalid_workspace": .herdr, "invalid_geometry": .herdr,
        "herdr_action_unsupported": .herdr,
        // herdr.md §Typing without taking the pane (HERDR-3)
        "invalid_key": .herdr, "herdr_key_unsupported": .herdr, "herdr_too_many_keys": .herdr,
        "invalid_text": .herdr, "herdr_text_too_long": .herdr, "herdr_pane_gone": .herdr,
        "not_seen": .herdr, "submit_failed": .herdr, "not_requested": .herdr, "herdr_agent_blocked": .herdr,
        // herdr.md §Starting a stopped session, making a new one (HERDR-5)
        "invalid_session": .herdr, "invalid_session_name": .herdr, "herdr_session_exists": .herdr,
        "herdr_session_start_failed": .herdr,
        // herdr.md §A new workspace in a chosen folder (HERDR-6)
        "invalid_folder": .herdr, "folder_outside_home": .herdr, "folder_private": .herdr,
        "folder_not_found": .herdr, "folder_unreadable": .herdr, "invalid_workspace_name": .herdr,
        // herdr.md §Starting an agent with it (HERDR-11)
        "herdr_launch_not_allowed": .herdr,
        // voice.md and audio-input.schema.json's two reason enums
        "voxtype_not_installed": .voice, "voice_uplink_disabled": .voice, "audio_input_busy": .voice,
        "audio_input_unsupported": .voice, "audio_input_unavailable": .voice,
        "audio_backend_not_installed": .voice, "audio_backend_unavailable": .voice,
        "audio_input_cleanup_pending": .voice, "audio_input_backpressure": .voice,
        "voxtype_wait_unsupported": .voice, "voxtype_config_unsupported": .voice,
        "voxtype_service_inactive": .voice, "microphone_permission_denied": .voice,
        "route_changed": .voice, "interrupted": .voice, "audio_session_error": .voice,
        "input_unavailable": .voice, "conversion_failed": .voice, "transport_closed": .voice,
        "backend_closed": .voice, "stream_closed": .voice, "host_unavailable": .voice,
        "voice_unavailable": .voice, "user_disabled": .voice, "session_end": .voice,
        "disconnected": .voice, "ready": .voice,
        // agent.md
        "existing_thread_handoff_required": .agent, "agent_busy": .agent, "agent_pane_busy": .agent,
        "handoff_rolled_back": .agent, "handoff_plan_expired": .agent, "handoff_target_changed": .agent,
        "handoff_stop_unconfirmed": .agent, "handoff_attach_unconfirmed": .agent,
        "handoff_thread_unconfirmed": .agent, "handoff_transport_unavailable": .agent,
        "agent_owner_start_failed": .agent, "agent_owner_start_timeout": .agent,
        "agent_owner_socket_unavailable": .agent, "thread_creation_unconfirmed": .agent,
        "provider_request_rejected": .agent, "structured_agent_kind_unsupported": .agent,
        "agent_state_unknown": .agent, "agent_blocked": .agent, "agent_not_working": .agent,
        "agent_kind_mismatch": .agent, "agent_kind_unsupported": .agent, "agent_chat_unavailable": .agent,
        "agent_approval_unknown": .agent, "agent_approval_decision_invalid": .agent, "agent_approval_changed": .agent,
        "agent_cli_rejected": .agent, "default_agent_unset": .agent, "default_agent_exists": .agent,
        "provider_adapter_failed": .agent, "provider_adapter_unavailable": .agent,
        "provider_thread_not_loaded": .agent, "provider_thread_not_materialized": .agent,
        "provider_thread_rollout_missing": .agent,
        "unmaterialized_empty_session_lost_after_host_restart": .agent,
        "task_too_large": .agent, "empty_task": .agent, "history_unavailable": .agent,
        "cancellation_pending": .agent,
        // agent-chat-new.schema.json, agent-chat-command(s).schema.json (AGENT-NEW-1)
        "agent_turn_active": .agent, "agent_approval_pending": .agent, "agent_identity_changed": .agent,
        "agent_mode_unavailable": .agent, "invalid_agent_mode": .agent, "agent_command_while_working": .agent,
        "agent_conversation_changing": .agent, "new_conversation_confirmation_required": .agent,
        "agent_thread_creation_unconfirmed": .agent,
        // AGENT-PLAN-1: agent-chat-commands.schema.json still names these for
        // older Apps; this one never asks that route (what is typed is sent
        // as typed), so they share one sentence.
        "command_terminal_only": .agent, "command_settings_on_computer": .agent,
        "command_sessions_on_computer": .agent, "command_not_on_phone_yet": .agent,
        // workspace-layout-action.schema.json and local-integration.md
        "workspace_layout_applied": .workspace, "workspace_layout_failed": .workspace,
        "workspace_layout_command_failed": .workspace, "workspace_layout_outcome_unknown": .workspace,
        "workspace_preflight_unavailable": .workspace, "invalid_workspace_request": .workspace,
        "stale_plan": .workspace, "existing_file_conflict": .workspace, "no_focused_window": .workspace,
        "no_backup": .workspace, "newer_than_cutoff": .workspace,
        // hub.md, catalog-routes.md, shortcuts.schema.json, pairing.md
        "daemon_unavailable": .host, "daemon_restarted": .host, "live_state_unavailable": .host,
        "state_adapter_failed": .host, "state_adapter_source_changed": .host,
        "route_state_unavailable": .host, "route_unavailable": .host, "theme_unavailable": .host,
        "fonts_unavailable": .host, "font_not_found": .host, "icon_not_found": .host,
        "notifications_unavailable": .host, "apps_reader_unavailable": .host, "reader_failed": .host,
        "reader_missing": .host, "stale_catalog_revision": .host, "menu_source_changed": .host,
        "menu_action_changed": .host, "menu_surface_changed": .host,
        "binding_adapter_unavailable": .host, "condition_adapter_failed": .host,
        "condition_adapter_unavailable": .host, "condition_shape_unsupported": .host,
        "condition_disabled": .host, "condition_timeout": .host, "condition_spawn_failed": .host,
        "condition_pending": .host,
        // catalog-routes.md §Menu actions (MENU-4)
        "menu_action_needs_terminal": .host, "menu_action_empty": .host, "menu_row_not_invocable": .host,
        "graphical_session_unavailable": .host,
        "executable_missing": .host, "invalid_command": .host, "execution_failed": .host,
        "action_failed": .host, "runner_failed": .host, "control_request_failed": .host,
        "control_failure": .host, "setup_required": .host, "polkit_not_configured": .host,
        "pam_root_required": .host, "credential_registry_unavailable": .host,
        "authorized_keys_unreadable": .host, "discovery_integration_failed": .host,
        "discovery_registration_failed": .host, "desktop_entry_unavailable": .host,
        "desktop_entry_install_failed": .host, "preferences_invalid": .host,
        "socket_not_in_shared_runtime_root": .host, "queue_overflow": .host,
        "approval_outcome_unknown": .host, "already_authorized": .host,
        "added": .host, "replaced": .host, "timeout": .host,
        "unavailable": .host, "rate_limited": .host,
        // host-open.schema.json (LINKS-1)
        "open_not_mentioned": .host, "open_outside_roots": .host, "open_denied": .host,
        "open_executable": .host, "open_missing": .host, "open_source_gone": .host,
        "open_type_refused": .host, "open_url_refused": .host, "open_rate_limited": .host,
        "open_unavailable": .host,
        // pairing.md / http-error.schema.json `error.reason` (CORE-2)
        "credential_expired": .host, "credential_revoked": .host, "device_purged": .host,
        "unknown_credential": .host, "credential_renewal_not_due": .host, "plugin_credential": .host,
        "auth_unavailable": .host,
        // clipboard.md, listed in remote-api.md's error table (CLIP-1)
        "clipboard_sync_disabled": .host, "clipboard_write_disabled": .host,
        "clipboard_too_large": .host, "clipboard_not_text": .host, "clipboard_invalid": .host,
        "clipboard_unavailable": .host,
    ]
}
