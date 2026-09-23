# A root hooks — backend leg only

`VNCBackendAdapter.swift` is the actual small connection/stop adapter. It does not
copy the existing host transition state machine. A owns these five hooks:

1. Retain one adapter alongside the existing media coordinator. Inject
   `VNCForwardingOperations(start:close:)` using A's `SSHLoopbackForward.start`
   with current SSH options, existing credential-provider and trust callback.
   Its start closure receives B's validated VNCConnectionDescriptor, returns local
   loopback UInt16; close calls the same forward instance's async close.
2. After existing Host `/quiesced` responds with `connection.backend == "vnc"`,
   decode VNCConnectionDescriptor and `await vnc.connect(descriptor)`.
   This only starts forwarding/client. It does NOT claim frame-ready or invoke
   Host first-frame early. Keep lifecycle transitions serialized by the existing
   coordinator, exactly as its Sunshine backend leg.
3. Embed `VNCBackendCanvas(adapter:vnc)` for chosen VNC backend. The old convenience
   `VNCRemoteSurface(descriptor:localPort:)` remains available but do not render
   both views. Canvas does not connect, create routes, or own Panel/bar behavior.
4. `vnc.onFrameReady` is issued once for that descriptor generation, after exact
   framebuffer pixels/full coverage/native image/CADisplayLink. Route its width,
   height, connectionGeneration and geometryEpoch to the current transition's
   existing `/first-frame`, adding `framebuffer_complete:true`. The event exposes
   formatDescriptionObserved/displayLayerReady/framePresented flags from that
   actual native callback, not from descriptor receipt. Root still verifies its
   current lease/generation and performs the normal commit before global input.
5. On orientation/backend switch/exit, `await vnc.stop()` BEFORE acknowledging old
   media quiesced: pending forward task is cancelled and awaited; native RFB sends
   held-input releases and closes its socket; completion then closes SSH forward.
   Last UIImage remains as transition presentation. No new host resize/stop API.

`onFailure` gives ordinary UI feedback and parent recovery decision; the adapter
cleans its connection, never switches to Sunshine silently. `pointer(at:buttons:)`
and `key(_:down:)` are ready-gated passthroughs for A's shared input adapter.
Root Panel/keyboard overlays must still capture their own input; temporary layout
changes do not create a new descriptor or request Host resize.

Minimal shape (use actual A session providers, not placeholders in production):

    let forward = SSHLoopbackForward()
    let vnc = VNCBackendAdapter(forwarding: .init(
        start: { descriptor in
            try await forward.start(options: currentOptions,
                descriptor: descriptor,
                privateKeyProvider: existingKeyProvider,
                hostKeyValidator: existingTrustValidator)
        },
        close: { await forward.close() }))
    vnc.onFrameReady = { frame in /* same coordinator first-frame request */ }
    vnc.onFailure = { message in /* same Remote error/retry presentation */ }

Validation this slice: new adapter+existing descriptor/canvas compile/typecheck
against actual ObjC header and iOS17 SDK. No App-root code changed, no simulator
or Host operation, and no claim backend_root_connected is already true. Previous
real RFB decoder/input/resize probe remains separate evidence; not rerun here.
