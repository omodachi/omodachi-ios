# P4 native Shortcut component — 2026-09-17

Four independent Swift files. Production requires a real `ShortcutPanelTransport`;
there is no fallback fixture, new route stack, media dependency or host-script parser.
A owns shared root/HomeStore/client integration. B confirmed the contract below;
its endpoint implementation is separate and is not proven by these local tests.

## A: minimal integration

1. Add this directory through normal Xcode project source generation.
2. Retain one ShortcutPanelStore per host. Render `ShortcutPanelView(store:store,
   onCollapse: existingContainerCollapse)` in the controller idle page's right
   placeholder. Narrow/Remote overlays reuse the same store; A controls bounds.
3. `updateContext` supplies actual selected surface and host, plus current Remote
   session/connectionGeneration/geometryEpoch/inputReady when applicable. Supply
   stateRevision and targetToken from the SAME current host snapshot for focused
   window actions. The component does not derive focus from labels or video.
4. Controller works without a Remote session. On Herdr/Agent/SSH do NOT mount the
   global list; defensive model/store checks also suppress list requests there.
   Their default-hidden Panel and lightweight bar remain A's shared-root behavior.
5. Supply GUI coverage only for already-implemented, reachable controls using
   actual action_ref values. Workspace actions that the real bar exposes may be
   omitted; planned controls do not count. Do not infer coverage from English labels.
   If a control becomes unavailable, remove its coverage so the unique shortcut
   returns. Optional semantic capability mapping is reserved for explicitly
   provided metadata; B's current DTO does not pretend to include it.
6. On host catalog revision/availability change call refresh(). Updating unrelated
   stateRevision does not invalidate the list; changing host clears cross-host UI.
   Keep the store across collapse so query and scrollEntryID survive. A must not
   change stream dimensions simply because search keyboard/overlay appears.

The view is the existing design language's title/search/rows/brief result. It has
no modifier keys, D-pad, duplicate workspace grid, new topbar, global tabs or routing.
Rows show action first and the current key hint beneath. Fixed right sidebar stays
open after execution; no new auto-dismiss rule is embedded.

## B-confirmed wire contract

`GET /v1/shortcuts`:

    {contract_revision, revision, source:"hyprland", available, reason,
     items:[{id,label,shortcut_display,order,enabled,disabled_reason,
             action_ref,requires_target}]}

`ShortcutListDTO` decodes this and produces `ShortcutSnapshot`. available/reason
are optional for additive compatibility; an explicitly unavailable provider is
not rendered as successful empty results. Unknown/custom bindings stay visible
but disabled with their host reason. Catalog identifiers are the execution source.

`POST /v1/actions/{action_ref}:invoke` uses the existing authenticated client:

    {request_id,catalog_revision,params:{},execution_context:{surface:"omarchy"},
     state_revision?,target_token?}

or Remote context:

    {surface:"remote",session_id,connection_generation,geometry_epoch}

All generation/epoch/revision numbers are Int; session/target are String.
`ShortcutInvokeBody` encodes the body only. Shared client owns URL escaping/auth.
Only requires_target rows need stateRevision/targetToken; missing values disable
those rows. No client-supplied command/Lua/key chord is an execution input.

Map actual Host results to accepted/applied/rejected/unknown accurately. accepted
means sent, not done. Errors/unknown are never automatically re-executed. An
execute completion never clears query, scroll or panel. Context changes discard
stale presentation updates, while the Host remains authoritative about execution.

## Validation

Run `python3 Tools/ShortcutPanelTests/run_tests.py`.
A synthetic snapshot matching B's DTO verifies sorting/search, actual-GUI-only
filtering, disabled unknown and missing target behavior, opaque invoke body,
no-stream controller mode, Remote generation fields, Herdr exclusion, unavailable
provider and preserving query/scroll after execution. Actual component source and
real Theme typecheck against iOS17 simulator SDK. No full App build, rendered GUI,
Host invocation or backend installation is claimed. The only fixture transport
lives under Tools/ShortcutPanelTests, outside production source.
