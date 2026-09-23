# Local SSH integration fixture

This fixture validates the real Citadel SSH transport without touching Omarchy,
a user's SSH keys, a real iOS device, or an external service. It binds only
`127.0.0.1:22222`, accepts the synthetic `omodachi-test` account/key, allocates a
local POSIX PTY with `os.openpty()`, and uses that PTY to echo raw bytes. Window
updates use `TIOCSWINSZ` and report the `TIOCGWINSZ` result. Input is never executed;
no shell/subprocess is launched and terminal contents are not logged.

The deterministic fixture keys (`0x48` host seed and `0x4F` client seed) are public
test material and must never be authorized on a real host. Tests use the actual
iOS System Keychain, under unique `com.omodachi.tests.ssh.*` services. Cleanup
removes the temporary private key and host pin and asserts both are absent.

The four integration tests start and stop this fixture themselves, so a plain
`scripts/build.sh test` covers them. `SSHTransportIntegrationTests.setUp` looks
for a python3 that can import `asyncssh` (`$OMODACHI_FIXTURE_PYTHON`, then
`$OMODACHI_FIXTURE_VENV` — default `/tmp/omodachi-ssh-fixture-venv` — then
Homebrew and system python3), creates that virtualenv from `requirements.txt` if
none exists, spawns `server.py`, and waits for a real TCP connection on 22222. A
fixture that is already listening is reused and never killed. The one skip the
suite can produce is "no python3 with asyncssh could be found or created", and it
names what went unvalidated.

To run only this suite with its own private DerivedData and result bundle:

```sh
Tools/SSHFixture/run-tests.sh
```

The script creates a temporary Python environment if needed, installs the pinned
AsyncSSH test dependency, starts its own fixture, runs the Simulator suite with
private DerivedData and Simulator ad hoc signing, and stops the fixture on exit.
The suite then reuses that already-listening fixture instead of starting a second
one. If the port is already in use, script startup fails; it never kills another
service. Set
`OMODACHI_SIMULATOR_DESTINATION` to choose another installed Simulator and
`OMODACHI_SSH_TEST_OUTPUT` for the evidence directory. No remote host is accepted
by the fixture script. Ad hoc Simulator signing uses no development team or real
device. Disabling signing causes System Keychain to reject access (`-34018`) on
the validated Simulator; the test runner deliberately leaves signing enabled.

To keep a fixture running manually:

```sh
python3 -m venv /tmp/omodachi-ssh-fixture-venv
/tmp/omodachi-ssh-fixture-venv/bin/pip install -r Tools/SSHFixture/requirements.txt
/tmp/omodachi-ssh-fixture-venv/bin/python Tools/SSHFixture/server.py
```

The four integration tests run by default and own their fixture. A skipped result
is not evidence; the suite skips only when no python3 with `asyncssh` exists and
none can be created.

Coverage:

- Correct pinned public-key authentication from actual System Keychain, POSIX PTY
  startup, Chinese UTF-8 split across writes, verified `93×31` resize, disconnect,
  post-disconnect write rejection, and a second independent connection.
- Mismatched server host key is rejected, with the actual key challenge observed
  and the previously stored pin unchanged.
- An unauthorized username is rejected after the host key was checked.
- Disconnect while the real host-key callback is pending cannot resurrect a PTY
  after validation completes.

These checks do not prove Herdr attach or default-agent residency, hardware-keyboard
behavior, iOS background survival, or device signing. They exercise the local
SSH/PTY mechanism only; those other G-TERM/G-AGENT items require separate evidence.
