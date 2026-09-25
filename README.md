# omodachi-ios

The Omodachi app: an iPhone and iPad client for one
[Omarchy](https://omarchy.org) desktop you own.

<p>
  <img src="https://omodachi.app/img/shots/demo-ipad-menu.webp" width="560" alt="The app on an iPad in demo mode: the Omarchy menu beside the keybindings">
  <img src="https://omodachi.app/img/shots/demo-iphone-menu.webp" width="200" alt="The app on an iPhone in demo mode: the Omarchy menu">
</p>

<sub>Demo mode, on mock data. More at <a href="https://omodachi.app">omodachi.app</a>.</sub>

## Where this sits

Omodachi turns an iPhone or iPad into an extension of an Omarchy desktop. It
ships as four repositories, plus the site.

| Repository | What it is |
| --- | --- |
| [`omodachi-plugin`](https://github.com/omodachi/omodachi-plugin) | the Omarchy plugin: the bar icon, the panel and one-step pairing |
| [`omodachi-core`](https://github.com/omodachi/omodachi-core) | the host daemon, where the weight of the system sits |
| **`omodachi-ios`** | **this repository: the native iPhone and iPad app** |
| [`omodachi-sunshine`](https://github.com/omodachi/omodachi-sunshine) | the Sunshine fork that drives the remote screen |
| the site | **omodachi.app**. Its source is not published |

The app gives that one machine six panels and a bar of its own instead of a
single remote-desktop window.

- **Panel** — the merged Omarchy menu, the keybinding actions and the
  workspaces, drawn from the host's own catalog. Rows pin.
- **Remote** — a second display for the iPad, or the whole desktop taken over,
  streamed through the managed Sunshine fork with absolute touch, a touchpad
  mode and shortcut injection.
- **Agent** — a native chat surface talking to the default agent on the host,
  with tool rows, slash commands, approval cards, per-turn model and effort
  overrides, a usage bar, and steer or interrupt on a running turn.
- **Herdr** — the host's own Herdr session as a touch grid, streamed through
  the official observe and control bridge. Its controls are routes, never key
  codes.
- **SSH** — a direct SSH PTY rendered by SwiftTerm, with a modifier assist row
  and hardware-keyboard support.
- **Notifications** — what the Omarchy shell already wrote down, with the
  shell's own two actions and its Do Not Disturb switch.

Two things cut across all of them. **Voice** is push-to-talk into the host's
own Voxtype; this app runs no speech recognizer and keeps no audio. It opens
`GET /v1/voice/uplink`, sends 48 kHz s16le mono in 960-sample frames, and the
words come back from the host.

There is **no background push**. A notification or an approval reaches the
phone while the app is holding the event stream, and a local notification is
raised from that stream when the app is not in front. Once iOS suspends the app
there is no stream, so there is nothing to deliver. This product has no APNs.

Everything the app draws with comes from the paired host at runtime: the
palette, the alphas, the sizes and the type scale from `GET /v1/theme`, the
monospace family and Omarchy's private icon font from `GET /v1/fonts`.

## Install

**Not yet available from the App Store.** Version 0.1.0 was submitted to App
Store review on 2026-09-25 and is not live. TestFlight is open to an internal
testing group only. Until a public release, the app is built from source.

The app is version **0.1.0** (`MARKETING_VERSION` in `project.yml`), the same
number as the Omarchy plugin and the release tag. `CFBundleVersion` is not a
version: it is the build minute stamped by `scripts/build.sh`.

No Omarchy computer yet? The first screen's last row, **Explore the demo**,
opens the app over made-up data. It connects to nothing, and a banner on top
says so.

What you need: a Mac with **Xcode 27** (the iOS 27 simulator runtime for the
simulator targets), `xcodegen`, and `python3`. The Swift packages below are
resolved by Xcode through Swift Package Manager on the first build; nothing
else is fetched.

```sh
scripts/build.sh generate      # xcodegen -> Omodachi.xcodeproj
scripts/build.sh build-sim     # Debug build for the iPhone simulator
scripts/build.sh test          # unit and UI, iPhone and iPad destinations
scripts/build.sh build-device  # generic/platform=iOS, CODE_SIGNING_ALLOWED=NO
scripts/build.sh archive       # Release archive, generic/platform=iOS, unsigned
scripts/build.sh all
```

Everything the script builds lands in `$OMODACHI_DERIVED_DATA`, which defaults
to `$TMPDIR/omodachi-ios-derived`. Nothing is written into the repository.
The simulator targets create their own simulators, address them by udid and
delete them on exit; set `OMODACHI_IPHONE_DESTINATION` and
`OMODACHI_IPAD_DESTINATION` to use simulators of your own instead.

Two flags are not optional on Xcode 27: `-skipPackagePluginValidation` and
`-skipMacroValidation`. SwiftTerm's build plugin fails validation otherwise.
The script always passes them; pass them yourself if you call `xcodebuild`
directly.

**Signing.** The repository ships with no team (`DEVELOPMENT_TEAM: ""` in
`project.yml`). For a build you can run on your own device, open
`Omodachi.xcodeproj` in Xcode, pick the `Omodachi` scheme, set **Signing &
Capabilities → Team** to your own Apple Development team for the `Omodachi`
target, change the bundle identifier `app.omodachi` to one your team can
register, and run. The computer needs `omodachi-core` installed and reachable
on the same network; the Omarchy plugin installs it.

Toolchain: Xcode 27, iOS 17.0 deployment target, Swift 6 language mode with
complete strict concurrency on the app target, xcodegen for project generation,
and python3 for the SSH test fixture.

## Screenshots

None here. The site draws the interface: **omodachi.app**.

## Layout

| Path | What it is |
| --- | --- |
| `Omodachi/Shell/` | the app shell: the bar, the panel host, the panel registry, routing |
| `Omodachi/Surfaces/` | one directory per panel |
| `Omodachi/Host/` | the companion client and the host wire types |
| `Omodachi/Remote/` | the Moonlight-backed stream, input, geometry and the lease |
| `Omodachi/Herdr/`, `Omodachi/SSH/`, `Omodachi/Agent/`, `Omodachi/Voice/` | the bridges behind those panels |
| `Omodachi/Security/` | credentials, pinning, approvals, keys |
| `Omodachi/DesignSystem/` | tokens, primitives and the type scale |
| `OmodachiTests/`, `OmodachiUITests/` | unit tests, and navigation suites plus operator tests that only run against a real host |
| `CoreFixtures/` | canonical host JSON the tests decode; every file here is read by a test |
| `packages/RemoteInputCore/` | a local SwiftPM package of pure input mapping, no UIKit |
| `Vendor/Moonlight/` | Moonlight iOS 9.0.2 plus our patches, recorded in `Vendor/Moonlight/PATCHES.md` |
| `Vendor/LibVNCClient.xcframework/` | the VNC fallback backend |
| `Tools/SSHFixture/` | a loopback-only synthetic SSH server used by the integration tests |
| `project.yml` | the source of truth for the Xcode project, which is generated |

## Dependencies

| Dependency | Version | Why |
| --- | --- | --- |
| [Citadel](https://github.com/orlandos-nl/Citadel) | 0.12.0 | SSH client and PTY channel |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.20.0 | terminal emulator view |
| [OpenSSL-Package](https://github.com/krzyzanowskim/OpenSSL-Package) | 3.3.2000 | required by the Moonlight crypto and pairing code |
| Moonlight iOS | 9.0.2, vendored | the streaming client: common-c, ENet, SDL2, Opus, FFmpeg |
| LibVNCClient | 0.9.15, vendored xcframework, rebuilt by `scripts/build_libvncclient.sh` | the VNC fallback backend |
| `asyncssh` | 2.21.1, pip, test only | backs `Tools/SSHFixture/server.py` |

`Package.resolved` pins `swift-nio-ssh` to `github.com/Joannis/swift-nio-ssh`
0.3.5, which is Citadel's own maintainer fork rather than a stranger's.
`docs/THIRD-PARTY.md` lists what is inside the bundle and under which licence.

## Licence

**GPL-3.0.** See [LICENSE](LICENSE). This repository was not free to choose.
Two vendored components are copyleft:

| Component | Licence | Text |
| --- | --- | --- |
| `Vendor/Moonlight/` — Moonlight iOS, moonlight-common-c | **GPL-3.0** | `Vendor/Moonlight/LICENSE.txt` |
| `Vendor/LibVNCClient.xcframework/` — LibVNCClient | **GPL-2.0-or-later** | `Vendor/LibVNCClient.xcframework/LICENSE` |

Both are linked into the one app binary, so a distributed build is a combined
work and has to be offered under **GPL-3.0**, which is the one version both
licences reach. Anything else needs those components replaced or relicensed.
[`docs/THIRD-PARTY.md`](docs/THIRD-PARTY.md) lists every component in the
bundle and the licence each one carries.

The rest of Omodachi is not bound by this. `omodachi-core` and the Omarchy
plugin are MIT; only this app is GPL-3.0.

Four of the vendored components are prebuilt static libraries: LibVNCClient,
FFmpeg, Opus and SDL2. The exact upstream source and build recipe of each is
recorded in `Vendor/LibVNCClient.xcframework/BUILD.md` and
`Vendor/Moonlight/libs/PROVENANCE.md`. LibVNCClient is rebuilt from its pinned
upstream tag by `scripts/build_libvncclient.sh`, and that rebuild matches the
committed binary; it carries one small iOS change to upstream, shown in
`BUILD.md`. FFmpeg is LGPL and statically linked; since this whole app is
source, it can be rebuilt against a modified FFmpeg.

**Distribution.** The app is offered free, under the same GPL-3.0, with this
repository as the source. Where that stands on 2026-09-25:

- TestFlight: open to an internal testing group only.
- App Store: version 0.1.0 was submitted for review on 2026-09-25. It is not
  live.
- The FSF has held Apple's store terms to conflict with the GPL, so the
  maintainers of Moonlight and LibVNCServer were asked on 2026-09-25 for an
  additional permission covering App Store distribution. **No permission has
  been granted.** LibVNCServer's maintainer replied that he is not the only
  copyright holder and cannot grant or refuse one on the others' behalf, and
  left it to our own judgement; that is not a permission. Moonlight has not
  replied. The App Store build goes ahead on that basis, at our own risk: any
  copyright holder of either project can ask Apple to take it down, and
  building from source stays available whatever happens there.

## Contributing

Issues and pull requests are welcome. Run `scripts/build.sh test` before you
open one, and say which Xcode and iOS versions you ran against. A change to
what the host sends belongs in `CoreFixtures/` in the same commit, because
every fixture there is read by a test.

---

Omodachi is an independent project with no tie to Omarchy upstream.
