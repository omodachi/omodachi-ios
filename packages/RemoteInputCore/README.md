# RemoteInputCore

`RemoteInputCore` is a standalone, Foundation-only input layer for the native Remote surface. It is deliberately outside `Omodachi/` so the Remote delivery owner can integrate it without two agents editing the app target or Xcode project.

The package exposes a typed `RemoteInputEvent` / `RemoteInputEventSink` bridge. An integration adapter can translate the payloads to `OMRemoteClient`/Moonlight calls:

- `.absolutePointer` → `LiSendMousePositionEvent`;
- `.relativePointer` and `.mouseButton` → the corresponding mouse calls;
- `.key` → `LiSendKeyboardEvent2` with the modifier snapshot;
- `.text(Data)` → `LiSendUtf8TextEvent`;
- `.releaseAll` → the media owner’s input-release routine.

No event contains shell syntax or a command string. A prompt or other text is a single data payload.

`VideoInputGeometry` maps viewport points through the actual displayed `videoRect` to decoded stream pixels. It rejects safe-area and letterbox/outside points, supports scale/offset transforms, rejects non-finite geometry, and derives relative deltas from the displayed video rectangle. `RemoteInputController` tags every event with both the connection generation and geometry epoch, rejects stale gesture/key calls, owns relative drag/cancel state, consumes or cancels Ctrl/Alt/Super latches, and releases held input on disconnect.

`HIDKeyboardMapper` covers the standard keyboard usages used by Moonlight’s iOS `KeyboardSupport`/`StreamView` path, including letters, digits, punctuation, function keys, navigation, keypad and left/right modifiers. Text insertion is kept separate from physical key events; a printable key carrying text emits one UTF-8 text event and suppresses its duplicate key-up.

## Integration request

The native Remote owner should add this package as a local package dependency and create one adapter owned by `OMRemoteClient`/`NativeMediaCoordinator`. The adapter should:

1. activate the current media generation only after the first presented frame has been confirmed;
2. pass the current `videoRect`, decoded `streamPixels`, viewport and safe-area geometry into `VideoInputGeometry`;
3. translate typed events to the existing OMRemoteClient input bridge;
4. call `disconnect(generation:)` before media stop, generation replacement, lease loss or input disable;
5. preserve the package’s generation and latch semantics instead of reconstructing them in SwiftUI.

This package has no real host/device access and the tests are not G4 media acceptance.

## Adapter ABI notes

`RemoteInputEvent.geometryEpoch` is a `UInt64` and is also available as `geometry_epoch` for protocol-shaped adapters. Activate a generation with `activate(generation:geometryEpoch:)`; gesture, latch and key/text entry points accept the same epoch and reject stale values. The package's `RemoteModifiers` bits are `control=1`, `alt=2`, `shift=4`, `superKey=8`; the native sink must explicitly translate these to the Moonlight/common-c bit layout rather than passing the raw value. `VirtualKey.rawValue` is the unflagged Windows VK; the stock bridge applies its `0x8000 | VK` encoding and `flags=0` at the adapter boundary.
