#!/usr/bin/env python3
"""POLISH-U: `CoreFixtures/` is core's `contracts/fixtures`, byte for byte, at one commit.

The tests decode the host's wire shapes from `CoreFixtures/`. Those files are
copies of omodachi-core's `contracts/fixtures/<name>`, and copies drift: by
REMOTE-INPUT-1 ten of them no longer matched any core anyone was running. So
the copies are pinned, the way the agent-face tokens are (check_motion_tokens):

    scripts/core-fixtures.lock   {"core_commit": <40 hex>, "files": {<name>: <sha256>}}

* `--check` (the default; `build.sh lint` runs it):
    - always: every `CoreFixtures/*.json` is in the lock with that sha256 and
      every locked name is there - a hand edit, or a file copied in by hand
      from some other core, fails;
    - when an omodachi-core checkout is reachable (`--core`, `$OMODACHI_CORE_TREE`,
      or an `omodachi-core` beside this repository or one of its parents), each
      file must also be `git show <core_commit>:contracts/fixtures/<name>` there.
      A checkout that does not have the commit is skipped with a note, unless
      it was named explicitly.
* `--write [--commit REV] [--add NAME ...]`: copy every locked fixture (and the
  added ones) from core at REV (default: the core checkout's HEAD) and rewrite
  the lock. This is the one way fixtures enter or change here.
* `--drift [--commit REV]`: list the fixtures whose core copy at REV (default
  HEAD) differs from ours, without changing anything.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "CoreFixtures"
LOCK = ROOT / "scripts" / "core-fixtures.lock"
CORE_PATH = "contracts/fixtures"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def read_lock() -> dict:
    try:
        lock = json.loads(LOCK.read_text("utf-8"))
    except (OSError, ValueError):
        return {"core_commit": None, "files": {}}
    if not isinstance(lock, dict) or not isinstance(lock.get("files"), dict):
        return {"core_commit": None, "files": {}}
    return lock


def write_lock(commit: str, files: dict[str, str]) -> None:
    body = {"core_commit": commit, "files": dict(sorted(files.items()))}
    LOCK.write_text(json.dumps(body, indent=2) + "\n", "utf-8")


def core_candidates(explicit: str | None) -> list[tuple[Path, bool]]:
    found: list[tuple[Path, bool]] = []
    if explicit:
        found.append((Path(explicit), True))
    if os.environ.get("OMODACHI_CORE_TREE"):
        found.append((Path(os.environ["OMODACHI_CORE_TREE"]), True))
    for parent in list(ROOT.parents)[:4]:
        found.append((parent / "omodachi-core", False))
    return found


def git(core: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(core), *args], capture_output=True)


def find_core(explicit: str | None) -> tuple[Path | None, bool]:
    for path, named in core_candidates(explicit):
        if (path / ".git").exists():
            return path, named
        if named:
            return None, True
    return None, False


def resolve(core: Path, rev: str) -> str | None:
    result = git(core, "rev-parse", "--verify", "--quiet", rev + "^{commit}")
    return result.stdout.decode().strip() if result.returncode == 0 else None


def core_file(core: Path, commit: str, name: str) -> bytes | None:
    result = git(core, "show", f"{commit}:{CORE_PATH}/{name}")
    return result.stdout if result.returncode == 0 else None


def ours() -> dict[str, bytes]:
    return {path.name: path.read_bytes() for path in sorted(FIXTURES.glob("*.json"))}


VERIFIED: list[str] = []


def check(explicit: str | None) -> list[str]:
    lock = read_lock()
    locked: dict[str, str] = lock["files"]
    have = ours()
    findings = []
    if not lock.get("core_commit"):
        findings.append(f"{LOCK.relative_to(ROOT)}: missing or unreadable - run "
                        "scripts/sync_core_fixtures.py --write")
    for name, data in have.items():
        if name not in locked:
            findings.append(f"CoreFixtures/{name}: not in the lock - add it with --write --add {name}")
        elif sha256(data) != locked[name]:
            findings.append(f"CoreFixtures/{name}: changed by hand - fixtures come from core "
                            "(scripts/sync_core_fixtures.py --write)")
    for name in locked:
        if name not in have:
            findings.append(f"CoreFixtures/{name}: in the lock but not in CoreFixtures/")
    core, named = find_core(explicit)
    commit = lock.get("core_commit")
    if core is None:
        if named:
            findings.append("the omodachi-core checkout named by --core / $OMODACHI_CORE_TREE is not there")
        else:
            print("sync_core_fixtures: no omodachi-core checkout beside this one; "
                  "checked the lock only", file=sys.stderr)
        return findings
    if commit and resolve(core, commit) is None:
        message = f"{core}: has no commit {commit}"
        if named:
            findings.append(message)
        else:
            print(f"sync_core_fixtures: {message}; checked the lock only", file=sys.stderr)
        return findings
    if commit:
        VERIFIED.append(f"{core} at {commit[:7]}")
    for name, data in have.items():
        if not commit:
            break
        theirs = core_file(core, commit, name)
        if theirs is None:
            findings.append(f"CoreFixtures/{name}: core {commit[:7]} has no {CORE_PATH}/{name}")
        elif theirs != data:
            findings.append(f"CoreFixtures/{name}: differs from core {commit[:7]} {CORE_PATH}/{name}")
    return findings


def write(explicit: str | None, rev: str, add: list[str]) -> int:
    core, _ = find_core(explicit)
    if core is None:
        print("sync_core_fixtures: --write needs an omodachi-core checkout (--core)", file=sys.stderr)
        return 2
    commit = resolve(core, rev)
    if commit is None:
        print(f"sync_core_fixtures: {core} has no {rev}", file=sys.stderr)
        return 2
    names = sorted(set(read_lock()["files"]) | set(ours()) | set(add))
    files, missing = {}, []
    for name in names:
        data = core_file(core, commit, name)
        if data is None:
            missing.append(name)
            continue
        target = FIXTURES / name
        if not target.exists() or target.read_bytes() != data:
            print(f"  {name}")
            target.write_bytes(data)
        files[name] = sha256(data)
    if missing:
        for name in missing:
            print(f"sync_core_fixtures: core {commit[:7]} has no {CORE_PATH}/{name}", file=sys.stderr)
        return 1
    write_lock(commit, files)
    print(f"sync_core_fixtures: {len(files)} fixtures at core {commit[:12]}")
    return 0


def drift(explicit: str | None, rev: str) -> int:
    core, _ = find_core(explicit)
    commit = resolve(core, rev) if core else None
    if commit is None:
        print("sync_core_fixtures: --drift needs an omodachi-core checkout with that commit", file=sys.stderr)
        return 2
    changed = [name for name, data in ours().items() if core_file(core, commit, name) != data]
    for name in changed:
        print(name)
    print(f"sync_core_fixtures: {len(changed)} differ from core {commit[:12]}", file=sys.stderr)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--core", help="an omodachi-core checkout (default $OMODACHI_CORE_TREE, then a sibling)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="the default")
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--drift", action="store_true")
    parser.add_argument("--commit", default="HEAD", help="core revision for --write / --drift")
    parser.add_argument("--add", action="append", default=[], help="a new fixture name, with --write")
    options = parser.parse_args()
    if options.write:
        return write(options.core, options.commit, options.add)
    if options.drift:
        return drift(options.core, options.commit)
    findings = check(options.core)
    for finding in findings:
        print(finding)
    if findings:
        print(f"\n{len(findings)} findings", file=sys.stderr)
        return 1
    print(f"sync_core_fixtures: {len(ours())} fixtures match the lock"
          + (f" and core ({VERIFIED[0]})" if VERIFIED else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
