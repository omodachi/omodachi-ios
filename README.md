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

The app gives that machine seven panels and a bar of its own instead of a
single remote-desktop window: the Panel behind the logo, and six more behind
the bar's entries. An iPhone and an iPad both get all of it.

- **Panel** — the merged Omarchy menu beside the keybinding actions, drawn
  from the host's own catalog. Rows in both halves pin. The workspaces sit on
  the bar.
- **Remote** — the desktop on this screen, as an extra display beside the
  computer's own or the whole desktop taken over. It streams through the
  managed Sunshine fork with absolute touch, a touchpad mode and shortcut
  injection. The other backend is WayVNC, reached through the host's own
  authenticated connection, with a one-finger pointer and the keyboard only.
  **Automatic** takes the host's default backend while it is available, and
  otherwise whichever one is, Sunshine first; Settings or Remote's Advanced row
  can pick either.
- **Agent** — a native chat with the host's default agent when that agent is
  Codex (the host serves the chat for Codex only): tool rows, slash commands,
  approval cards, per-turn model and effort overrides, a usage bar, and steer
  or interrupt on a running turn.
- **Herdr** — the host's Herdr sessions as a touch grid, Omodachi's own
  session first and your others one tap away, streamed through the official
  observe and control bridge. A pane is watched until you type into it. Its
  controls (focus, split, zoom, close) are routes, never key codes.
- **SSH** — a direct SSH PTY rendered by SwiftTerm, with a modifier assist row
  and hardware-keyboard support.
- **Settings** — the paired computer, Remote and stream preferences, gestures,
  which entries the bar shows, clipboard sharing, password approval,
  diagnostics, and About with the version, the build and the licences.
- **Notifications** — what the Omarchy shell already wrote down, with the
  shell's own two actions (run the notification's default action, dismiss it)
  and its Do Not Disturb switch.

There is **no background push**, and this product has no APNs. A password
prompt or an agent's request for approval reaches the device only over a live
connection; if the app is open but not in front at that moment, it raises a
local notification for it. Desktop notifications appear in the Notifications
panel and never become iOS notifications. When the app goes to the background
it drops the computer's event stream, and once iOS suspends it no connection
is left, so nothing can arrive.

Once paired, the app draws with the host's palette, alphas, sizes and type
scale from `GET /v1/theme`, and with the host's monospace family and
Omarchy's private icon font from `GET /v1/fonts`. Until it has reached a host,
and in the demo, it uses a bundled Tokyo Night placeholder theme, the system
monospaced font and a bundled symbols-only Nerd Font for icons. Prose, the app
icon and the bundled Codex and Herdr marks never come from the host.

**Voice is not in this build.** The push-to-talk uplink into the host's own
Voxtype is still in `Omodachi/Voice/`, but no control in the app starts it.

## Install

**Not yet available from the App Store.** Version 0.1.0 was submitted to App
Store review on 2026-09-25 and is not live. TestFlight is open to an internal
testing group only. Until a public release, the app is built from source.

The app is version **0.1.0** (`MARKETING_VERSION` in `project.yml`), the
number its release tag carries. `CFBundleVersion` is not a version: it is the
build minute stamped by `scripts/build.sh`.

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
to `$TMPDIR/omodachi-ios-derived`. The one thing written into the repository is
`Omodachi.xcodeproj`, which `generate` regenerates in place from `project.yml`
and which is committed.
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
on the same network; the Omarchy plugin installs it. The plugin is listed on the
[Omarchy plugin marketplace](https://plugins.omarchy.org/plugin.html?id=com.omodachi.host).

Toolchain: Xcode 27, iOS 17.0 deployment target, Swift 6 language mode with
complete strict concurrency on the app target, xcodegen for project generation,
and python3 for the string and identifier checks and the SSH test fixture.

## Security model

What the app keeps, whom it talks to, and what it can ask a computer to do.
What one Approve on the computer grants, and every check the computer makes,
is in `omodachi-core`'s README,
[Security model](https://github.com/omodachi/omodachi-core#security-model).
To report a vulnerability, see [SECURITY.md](SECURITY.md).

**What stays on the device.**

- For each paired computer: its device credential, the fingerprint of its TLS
  certificate and the SSH host key the terminal accepted. With them, the SSH
  private key. All are Keychain items that can be read only while the device
  is unlocked and are never synced or restored to another device
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; `Omodachi/Security/`).
- The SSH key is an Ed25519 key the app makes on the device when it first
  pairs. Only its public half is ever sent: with the pairing request, and
  again if the computer's copy has to be replaced.
- The key that answers a password prompt, only if you turn that on, is a P-256
  key made in the Secure Enclave where the device has one. It signs only after
  Face ID or Touch ID, with no passcode fallback, and is never exported.
- Remote's client identity for the Sunshine fork, a certificate and its key,
  is a Keychain item of its own, kept to this device.
- **Forget this computer** deletes that computer's credential, certificate
  fingerprint, SSH host key and approval key from the device. It revokes
  nothing on the computer: Remove on the plugin's Devices page does that.
- No account, no analytics, no crash reporting. The privacy manifest declares
  no tracking and no collected data (`Omodachi/PrivacyInfo.xcprivacy`), and the
  only web addresses built into the app are this repository and the privacy
  page, which Settings opens in the browser.

**Whom it talks to.** Only the computers you pick: found on the local network
with Bonjour, or added by name or address. The connection to the computer's
`omodachi-core` is TLS pinned to the certificate fingerprint recorded when
pairing succeeded, with no CA check; if that certificate changes, the app
refuses to connect until you trust the new one in Settings. The terminal
checks the computer's SSH host key against the one it accepted first.

**What it can ask a computer to do.** Once paired, its requests to
`omodachi-core` carry the device credential, and the computer decides. With
the grants of one Approve, the app can: run a row from the computer's own
Omarchy menu or keybindings, where a row that powers off, removes, updates or
needs root runs only on a second tap; start and end a Remote session, which
adds a display or moves the computer's workspaces and can lock its keyboard
and mouse; chat with the default agent and answer what it asks to run; watch,
type into, split, zoom and close Herdr panes; open an SSH terminal, if the
Approve granted one; open, dismiss and clear the desktop's notifications and
switch Do Not Disturb; share the clipboard, if the computer allows it; and
renew its own credential in its last week. Only where the computer's owner
installed that opt-in can it answer a `sudo` or polkit password prompt, with
Face ID or Touch ID.

## Screenshots

None in this repository. The pictures at the top are served by the site,
**omodachi.app**, which also draws the interface.

## Layout

| Path | What it is |
| --- | --- |
| `Omodachi/Shell/` | the app shell: the bar, the panel host, the panel registry, routing |
| `Omodachi/Surfaces/` | one directory per panel |
| `Omodachi/Host/` | the companion client and the host wire types |
| `Omodachi/Remote/` | the Moonlight-backed stream, input, geometry and the lease |
| `Omodachi/Herdr/`, `Omodachi/SSH/`, `Omodachi/Agent/` | the bridges behind those panels |
| `Omodachi/VNCRemote/` | the VNC client behind Remote's WayVNC backend |
| `Omodachi/Voice/` | the voice uplink, which nothing in this build starts |
| `Omodachi/Security/` | credentials, pinning, approvals, keys |
| `Omodachi/DesignSystem/` | tokens, primitives and the type scale |
| `OmodachiTests/`, `OmodachiUITests/` | unit tests, and navigation suites plus operator tests that only run against a real host |
| `CoreFixtures/` | canonical host JSON the tests decode |
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
committed binary; it carries one small iOS source change and one compiler
flag on top of upstream, both shown in `BUILD.md`. FFmpeg is LGPL and
statically linked; since this whole app is source, it can be rebuilt against a
modified FFmpeg. The upstream source of all four, and the scripts that built
FFmpeg, Opus and SDL2, are attached to the release of the App Store build, tag
`v0.1.0-b202609250225`, as well as linked to upstream; `docs/THIRD-PARTY.md`
lists the files.

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
what the host sends belongs in `CoreFixtures/` in the same commit, because the
tests decode the host's wire shapes from there.

---

Omodachi is an independent project with no tie to Omarchy upstream.
