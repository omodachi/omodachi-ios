# SSH/PTY Simulator validation — 2026-09-16

Local test date: 2026-09-16, Australia/Melbourne. Scope is local iOS Simulator to
loopback SSH only. No real iOS device, Omarchy host, remote service, user SSH key,
window title, agent content, or production log was accessed.

## Result

**4 passed, 0 failed, 0 skipped** in the actual iOS Simulator test process.
`validation-2026-09-16.json` is the unmodified compact xcresult summary.

- Device: existing iPhone 17 Simulator.
- OS: iOS 26.5 (23F77), arm64.
- SDK/compiler: Xcode 27.0 RC (27A266a), iOS Simulator SDK 27.0, Swift 6 mode.
- App: current Omodachi target, Citadel 0.12.1 linked.
- SSH server: AsyncSSH 2.21.1, loopback `127.0.0.1:22222` only.
- Terminal: actual local POSIX PTY from `os.openpty()`, raw mode; no subprocess.
- Credential storage: SystemKeychainRecordStore, not MemoryKeychain.

The selected suite executed:

| Test | Actual evidence |
|---|---|
| `testRealPTYUnicodeResizeAndReconnectUsingSystemKeychain` | Fresh temporary System Keychain private key and host pin; correct SSH public-key authentication; PTY ready; Chinese UTF-8 sent in two pieces splitting a multibyte scalar; exact echo; server-side `TIOCSWINSZ`/`TIOCGWINSZ` verified 93×31; disconnect; closed transport rejects further bytes; second independent authenticated PTY connection succeeds. |
| `testChangedHostKeyRejectsBeforePTY` | Actual SSH key challenge observed; mismatch rejected before PTY; existing System Keychain pin remained unchanged. |
| `testUnauthorizedUserRejectedAfterTrustedHostKey` | Actual host key checked; unauthorized synthetic username rejected. |
| `testDisconnectDuringHostKeyCheckDoesNotResurrectPTY` | Disconnect while the actual SSH host-key callback waits; validation allowed to complete; connect throws cancellation and emits no connected event. |

Each test cleans up its unique temporary Keychain service records. Cleanup reads
back the private key and host pin and asserts both are absent. The tests fail on
cleanup errors and missing fixtures. Assertions are not replaced by mocks or
unconditional skips.

## Reproduction command

```sh
xcodebuild -project Omodachi.xcodeproj -scheme Omodachi \
  -destination 'platform=iOS Simulator,id=E737AB77-0AED-4DE5-BCE8-894E1D5A1CC7' \
  -derivedDataPath /tmp/omodachi-ssh-simulator-validation \
  -resultBundlePath /tmp/omodachi-ssh-simulator-validation-9.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:OmodachiTests/SSHTransportIntegrationTests \
  test CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  -skipPackagePluginValidation
```

The fixture was started from `Tools/SSHFixture/server.py` before this command.
For a new run, `Tools/SSHFixture/run-tests.sh` starts/stops an owned fixture and
rejects xcresult summaries containing skipped, failed, or missing tests.

Raw evidence retained locally:

- `/tmp/omodachi-ssh-simulator-validation-9.xcresult`
- `/tmp/omodachi-ssh-simulator-validation-9.log`

## Failure found and fixed

The preceding actual Simulator run, with `CODE_SIGNING_ALLOWED=NO`, executed all
four tests and failed all four on Keychain `-34018`. These failures were not
skipped or counted as success. Simulator ad hoc signing (`CODE_SIGN_IDENTITY=-`)
resolved Keychain access without changing the app project, requesting a developer
team, or installing on a real device.

An intermediate rerun exposed a fixture sequencing race: its resize marker could
be inserted between the two raw UTF-8 echo fragments. The test now awaits complete
Chinese echo before requesting resize, so each property is verified independently.
That intermediate failure is retained in `/tmp/omodachi-ssh-simulator-validation-8.xcresult`; it was not counted
as passed. The final `/tmp/omodachi-ssh-simulator-validation-9.xcresult` passed all four actual tests.

The transport now rejects resurrection after disconnect during key loading or
host validation, does not publish a TTY writer after closure, and marks the
connection established before connect returns its ready writer. Explicit disconnect
finishes the event stream and suppresses late channel-close failures; the test
asserts connected/disconnected were emitted and no failure followed manual detach.

## Gate boundary

This is evidence for SSH authentication/host pin, System Keychain, SSH/PTY raw
Unicode bytes, terminal size requests, disconnect, and a fresh connection on
Simulator. It does not pass the complete G-TERM or G-AGENT gate. Real device IME,
hardware keyboard, touch UI, Split View/Stage Manager layout, foreground/background
behavior, real Herdr attach/reattach, explicit existing agent/pane handling, and
server/default-agent residency require their own validation. No Desktop lease,
Sunshine, or Moonlight fork was used.
