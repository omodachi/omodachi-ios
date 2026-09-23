# omodachi-ios

The Omodachi app: an iPhone and iPad client for one
[Omarchy](https://omarchy.org) desktop you own.

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

**TestFlight and the App Store are coming.** Until then, the app is built from
source.

What you need: a Mac with **Xcode 27** (the iOS 27 simulator runtime for the
simulator targets), `xcodegen`, and `python3`. The Swift packages below are
resolved by Xcode through Swift Package Manager on the first build; nothing
else is fetched.

```sh
scripts/build.sh generate      # xcodegen -> Omodachi.xcodeproj
scripts/build.sh build-sim     # Debug build for the iPhone simulator
scripts/build.sh test          # unit and UI, iPhone and iPad destinations
scripts/build.sh build-device  # generic/platform=iOS, CODE_SIGNING_ALLOWED=NO
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
target, change the bundle identifier `com.omodachi.ios` to one your team can
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
| LibVNCClient | vendored xcframework | the VNC fallback backend |
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

A TestFlight build and a free App Store listing are coming, offered under the
same GPL-3.0 with this repository as the source. There is no date.

## Contributing

Issues and pull requests are welcome. Run `scripts/build.sh test` before you
open one, and say which Xcode and iOS versions you ran against. A change to
what the host sends belongs in `CoreFixtures/` in the same commit, because
every fixture there is read by a test.

---

Omodachi is an independent project with no tie to Omarchy upstream.
