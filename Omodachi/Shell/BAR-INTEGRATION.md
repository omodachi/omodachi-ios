# Native bar C candidate — 2026-09-17

This candidate changes only BarState.swift, NativeTopBar.swift, NativeBar/ and
Tools/NativeBarTests/. A owns App/HomeStore/Remote integration and the complete
build. No host or Simulator operations were performed. Remote native bar
replacement is NOT enabled by this candidate.

## Implemented

- NativeTopBar preserves host left/center/right role order.
- `logo` and explicit `panel`/`omodachi` roles invoke the same `onPanel` callback.
- Workspace buttons are extracted to NativeWorkspaceButtons with explicit select
  and move callbacks, real IDs, selection/occupancy and host capability disabling.
  Each target is 44 × 44 points. No workspace IDs are fabricated.
- Removed misleading display of local terminal state as system tray, and host
  agent usage as native Agent session state. These unsupported widgets are omitted.
- Existing clock still displays client-local time, not host timezone state. It is
  not evidence of remote clock synchronization. Host clock state is future work.
- NativeBarPlacement resolves actual window geometry to the long edge, with
  separately Codable landscape top/bottom and portrait left/right preferences.
  Square geometry retains the prior edge; invalid/temporary viewport events do
  not move it. Keyboard and Panel occlusions explicitly do not change placement.

## Minimal A integration

1. Add NativeBar/NativeWorkspaceButtons.swift to the project source list using
   the normal project.yml/Xcode generation when producing the unified candidate.
2. Keep NativeBarPlacement in the root view. Restore its `preferences` from local
   storage (JSON Codable); call `choose(edge)` on user preference changes and save
   preferences. Do not overwrite preferences each time host bar position changes.
3. Feed `update(width:height:reason:.windowGeometry)` with the OUTER usable window
   bounds, before keyboard/Panel layout reductions. Use `.temporaryOcclusion` or
   no update for keyboard and Panel. Device orientation notification alone is not
   adequate; actual resizable window geometry owns orientation.
4. The root's top/bottom/left/right container switch must use placement.edge, and
   pass `positionOverride: placement.edge` to NativeTopBar. Both must use the same
   edge. Old callers without the override deliberately retain host position.
5. Pass `onPanel` to NativeTopBar before `positionOverride`, before trailing closure.
   It opens the existing shared native Panel; do not open a host menu. Current
   root does not yet pass this callback, so logo remains disabled until integrated.
6. Non-Remote NativeTopBar uses HomeStore workspace actions. For Remote reuse
   NativeWorkspaceButtons with the lease-scoped workspace select route/revision
   from B. Do NOT reuse HomeStore.workspace to migrate Remote desktop implicitly.

Call shape (adapt only the actual existing state transitions):

    NativeTopBar(onSetup: ..., onShell: ..., onRemote: ...,
        remoteStatus: ..., remoteHasFrame: ...,
        onPanel: { /* existing shared native Panel navigation */ },
        positionOverride: placement.edge) { EmptyView() }

## Remote integration gate

Do not add this bar over a streamed host bar. First agree with B on hiding only
that session/output's host bar and restoring it on disconnect/failure. One owner
must compute remaining video viewport and send the resulting stream dimensions.
During geometry reconfiguration, disable bar workspace actions and remote input
until the new geometry/frame is committed. Old retained video is presentation
only and cannot remain an interactive old-coordinate surface. Insets, pointer
mapping, and first-frame ready gate belong to A. Root container can use
`.disabled(!remote.inputReady)` for lease-mutating native workspace controls.

## Host data versus local actions

- `state.bar`: source status, revision, position and host module order.
- `state.workspace.items`: true non-Remote workspaces and capabilities (B fixing
  legacy fabricated 1…10 list separately).
- `state.remote_bar.workspaces`: real lease/output-scoped workspaces for Remote;
  select through `/v1/sessions/{lease}/workspace` with current revision.
- Panel button is a local native navigation action, independent of widget scripts.
- Arbitrary QML widgets, system tray actions and agent usage widgets are not
  interpreted as native code or replaced by unrelated client state.

## Validation

Run `python3 Tools/NativeBarTests/run_tests.py` from the iOS project or equivalent
absolute path. It checks 19 contract/layout/preference assertions and typechecks
actual NativeTopBar/NativeWorkspaceButtons against the iOS17 simulator SDK using
small test-only HomeStore/Theme stubs. No whole App build or gesture/host proof.
