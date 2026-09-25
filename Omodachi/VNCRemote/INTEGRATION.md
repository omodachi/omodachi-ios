# P10 native RFB candidate

**This is real LibVNCClient decoding + native UIKit framebuffer rendering.** No
WKWebView/noVNC and no hand-written production RFB protocol. C changed only this
independent module and Tools/VNCRemoteTests. A owns project/SSH/root integration;
B owns output/backend/session APIs. No Host or Simulator operations performed.

## Fixed dependency, build and minimum project changes

Pinned LibVNCServer-0.9.15 / LibVNCClient, source SHA256
`62352c7795e231dfce044beb96156065a05a05c974e5de9e023d688d8ff675d7`.
Official source: https://github.com/LibVNC/libvncserver/tree/LibVNCServer-0.9.15
License GPL-2.0-or-later: GPLv2 text at `Vendor/LibVNCClient.xcframework/LICENSE`. This is a
functional candidate, not a claim that final project/App Store distribution and
licensing have been reviewed.

Built dependency: `Vendor/LibVNCClient.xcframework` contains arm64 iOS
Simulator and arm64 iOS device static libraries. Source, changes, build flags
and a byte-level reproduction check: `Vendor/LibVNCClient.xcframework/BUILD.md`.

Rebuild (the original `Tools/VNCRemoteTests/build_dependency.py` was removed in
`afa7a61`; this script performs the same steps):

    scripts/build_libvncclient.sh --compare

The script fixes the immutable source archive hash. Only source patch disables
unused reverse-listen fork on iOS. `-include unistd.h` fixes upstream missing POSIX
declarations under modern clang. Compression/TLS/JPEG extensions are off in this
first candidate; raw/hextile baseline runs over existing authenticated SSH.
No new VNC account/password, no raw LAN listener, no changes to user SSH settings.

A project additions (C did not edit project.yml/Xcode):

1. Add/copy the frozen XCFramework to the dependency location A owns, link it
   statically to the iOS target, and expose its `Headers` to OMVNCClient.c.
2. Compile this module's .c/.m/.swift files (ObjC ARC on); add
   `#import "VNCRemote/OMVNCRemoteView.h"` to the existing bridging header.
3. Link UIKit/CoreGraphics/QuartzCore via the normal iOS SDK. No extra package or
   OpenSSL symbol collision is introduced by this minimal library build.
4. Render VNCRemoteSurface only when the user explicitly selects VNC; retain the
   same parent Remote/Panel/Shortcut/session navigation. No silent fallback.

## Existing SSH channel, not a terminal PTY

Current Citadel checkout exposes public
`SSHClient.createDirectTCPIPChannel(using: SSHChannelType.DirectTCPIP, initialize:)`.
It supplies ByteBuffer codec itself. A confirmed existing credentials/trust can be
reused with a dedicated forwarding connection/channel; do not hijack a private
terminal transport or stuff RFB bytes into PTY.

C library uses BSD sockets; A's adapter should provide a loopback-only local TCP
listener forwarding to B's descriptor host=127.0.0.1/port through directTCPIP.
Pass its **local** port to VNCRemoteSurface/OMVNCRemoteView. Only forward the
Host-returned endpoint for the current authorized session; do not expose it to LAN.
Stop the local forward after the client disconnect callback completes.

## Exact B connection and transition contract

Initial existing POST /v1/sessions accepts backend:vnc|sunshine.
Switch `/v1/sessions/{lease}/backend` carries lease_epoch, backend,
connection_generation, geometry_epoch; returns prepared. Stop/release the old
backend, then call the **existing** quiesced route. No invented stop-ACK endpoint.

Quiesced response `connection` fields consumed by VNCConnectionDescriptor:

    backend: vnc
    transport: ssh-forward
    host: 127.0.0.1
    port: Int
    output_id: String
    framebuffer_pixels: {width: Int, height: Int}
    connection_generation: Int
    geometry_epoch: Int
    automatic_resizing: false

Host owns resize; WayVNC uses -R. Native surface receives a descriptor only after
Host applied the output geometry. Full new framebuffer matching expectedPixels
is required before inputReady. C coverage tracks every initialized pixel and only
publishes at FinishedFrameBufferUpdate, including split rectangle initialization.
A must combine native frame callback with current-generation transition and send
existing /first-frame fields, including framebuffer_complete:true. A geometry
change explicitly disables input before Host mutation; temporary Panel/keyboard
occlusion does not request resize.

The UIImage is installed in the native layer and a CADisplayLink tick fires before
onFramePresented. This is not a physical-display measurement; A must actually
observe the screen for end-to-end acceptance. Wrong-size frames remain hidden.
The Swift wrapper reconnects when descriptor/generation changes (controlled
reconnect is allowed). Same-connection server DesktopSize is also supported by C.

Use `disconnectWithCompletion` for /quiesced ordering: completion runs after held
keys/buttons are released and LibVNCClient/socket destroyed. Do not call quiesced
immediately after requesting disconnect. Keep the old image visible until replacement.

## Input and limits

Native view has aspect-fit direct single-touch pointer/down/drag/up with letterbox
rejection. `sendPointerAtViewPoint:buttons:` and `sendKeysym:down:` are explicit
hooks for A's shared mouse/touchpad/keyboard mapping. Input before complete frame
is refused; resize/exit releases held input. This candidate does not independently
implement all multitouch, IME, clipboard or audio. B reports audio:false for this
media backend; existing separate audio channel work is unaffected.

## Concrete verification

- LibVNCClient static library builds for macOS plus arm64 iOS Simulator/device.
- C bridge and ObjC UIKit renderer compile for arm64 iOS Simulator.
- Actual Swift UIViewRepresentable/descriptor typechecks against iOS17 SDK.
- Controlled loopback RFB3.8 server sends genuine handshake, pixel format, raw
  rectangles in partial updates, then DesktopSize resize and new pixels. Real
  LibVNCClient decoder completes exact RGBA contents; probe observes two frames
  only after complete coverage, sends pointer/key down, server sees release on exit.

Tools/VNCRemoteTests/loopback_probe.py is only a test peer, not production protocol.
No actual WayVNC/Host/SSH/video presentation/backend switch has been validated yet.
A/B next: install candidate, establish forward, receive actual host frame, perform
click/keys and rotation, switch Sunshine→VNC→Sunshine preserving work and outputs.
