# Omodachi native media integration

Vendored on 2026-09-16 from Moonlight iOS **9.0.2**, commit
`85af0f75622bb2636481afda8b0fc5cc33d5956e`, with the initial isolated adapter
commit `183b01a949f2e4c6a198b989bc3ce49ff9c7e137`. Exact common-c and ENet pins
are in `provenance.json`. `LICENSE.txt` is the upstream license. The bundled
SDL2, Opus and FFmpeg iOS archives and headers are copied from that upstream
checkout, with its `libs/Build*.txt` recipes. They are linked into the existing
Omodachi target; no stock Moonlight app target or host database is launched.

Local changes:

- `Stream/Connection.m`: process-wide initialization lock; generation;
  cancellation checked before start; interrupt retried while actual start holds
  the lock; stop completion emitted only after `LiStopConnection` returns and
  the lock is released. Static renderer/callback owners are released afterward.
- `Stream/Omodachi`: `setPublishesObservationEachTick:` forwards the renderer's
  observation policy. The common-c owner remains strongly retained until explicit
  invalidation completes. Startup runs separately from lifecycle callbacks, so
  stop can interrupt a blocked startup. Held input release occurs before stop.
  No manual duplicate renderer setup; no NSOperation-finished stop signal.
- `Stream/VideoDecoderRenderer`: UIView-only dependency, decoded parameter-set
  dimensions, current generation observation, display-tick aspect-fit layout,
  ready and copied displayed-pixel-buffer observations. Enqueue and requested
  dimensions never satisfy first-frame. Physical scanout remains unverified.
  PERF-1: the display tick's observation is opt-out
  (`publishesObservationEachTick`). Each one copies the displayed pixel buffer
  and lays the video layer out a second time on the thread that submits decode
  units; a consumer that has latched its geometry turns it off and something
  that invalidates that geometry turns it back on. The aspect fit no longer
  reassigns an unchanged layer frame. A Debug-only counter reports received /
  rendered / observed frames and main-thread time per tick to os_log
  (`com.omodachi.ios`, category `perf`) once a second.
- STREAM-1: `OmodachiMediaFacade.copyStreamStats:` returns the one-second
  window `Connection` already counts (total / received / network-dropped
  frames, Sunshine's host processing latency), `LiGetEstimatedRttInfo`, the
  active video format and a release-build count of sample buffers the
  renderer enqueued (`VideoDecoderRenderer.enqueuedFrameCount`). Only while
  the facade is Running, which is exactly the window common-c allows the RTT
  call in. No decode timing: AVSampleBufferDisplayLayer decodes internally.
- `Network/HttpManager`, `HttpResponse`, `PairManager`: remove stock CoreData
  dependencies; read HTTPS port directly from serverinfo; own persisted client
  ID and device name; suppress request/XML/PIN/launch-key logging. TLS accepts
  only the PIN-authenticated pinned certificate. Redirects are rejected.
- `Crypto/CryptoManager`: the generated RSA PEM/certificate/PKCS12 and per-host
  server pins use this app's independent Keychain service
  `com.omodachi.sunshine.identity.v1`, ThisDeviceOnly. Existing Companion and
  SSH stores are unrelated. No stock client identity is imported.
- `Utility/Utils`: client display name is Omodachi.

The product bridge is `Omodachi/Remote/OMRemoteClient.*`. It performs actual
serverinfo, Sunshine PIN pairing, Desktop applist selection, launch/resume,
H.264/Opus streaming and real input calls. Busy sessions resume only when their
actual app ID matches the discovered Desktop ID. NativeMediaCoordinator owns
lease, heartbeat, profile and five-phase transactions through the existing
Companion client. Default adaptive mode requires the actual host adapter;
Existing display is an explicit fixed-stream baseline, not adaptive acceptance.

These sources build through the ordinary `scripts/build.sh` entry point; the
separate `Tools/NativeRemote/build.py` wrapper is gone. Xcode 27 needs
`-skipPackagePluginValidation -skipMacroValidation`, which the script always
passes. Compilation is not a media, physical-device, rotation, audio,
input-mapping or performance acceptance result.
