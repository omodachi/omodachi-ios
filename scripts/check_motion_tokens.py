#!/usr/bin/env python3
"""MOTION-1: the agent-face tokens are the brand's file, byte for byte.

Pinned brand source (omodachi-brand, branch agent-motion):
    BRAND_COMMIT  = 8318df51dc07d32c371bcca078cea5c9438ef6ed
    BRAND_PATH    = agent-motion/tokens.json
    TOKENS_SHA256 = 1575a6bf69c37e0f252d2ee9678d4644ad35c81be0fc452caa904839287a0303

`tokens.json` is the single source of the face's numbers (iOS `AgentFace`,
Odomo `agentFace.js` in omodachi-core). This repository keeps a verbatim copy; this script fails
when the copy is not the brand file at the pinned commit:

* always: the copy's sha256 must be TOKENS_SHA256 (recorded above when the pin
  was taken from `git show BRAND_COMMIT:BRAND_PATH`);
* when an omodachi-brand checkout is reachable (`--brand`, `$OMODACHI_BRAND`,
  or a sibling `omodachi-brand` next to the repository), the copy must also be
  byte-identical to `git show BRAND_COMMIT:BRAND_PATH` in it;
* the golden frames exported from the study must name the same commit.

To move the pin: change the three values above (and in the sibling repo's copy
of this script), copy the new file, regenerate the golden frames with
omodachi-core `odomo/scripts/agent-face-golden.mjs`, and run the tests.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

BRAND_COMMIT = "8318df51dc07d32c371bcca078cea5c9438ef6ed"
BRAND_PATH = "agent-motion/tokens.json"
TOKENS_SHA256 = "1575a6bf69c37e0f252d2ee9678d4644ad35c81be0fc452caa904839287a0303"

ROOT = Path(__file__).resolve().parents[1]
# This repository's copies (paths relative to ROOT).
COPIES = ["Omodachi/Resources/AgentMotionTokens.json"]
GOLDEN = ["OmodachiTests/Golden/agent-face-golden.json"]


def brand_candidates(explicit: str | None) -> list[Path]:
    found = [Path(explicit)] if explicit else []
    if os.environ.get("OMODACHI_BRAND"):
        found.append(Path(os.environ["OMODACHI_BRAND"]))
    for parent in list(ROOT.parents)[:4]:
        found.append(parent / "omodachi-brand")
    return found


def brand_bytes(explicit: str | None) -> tuple[bytes | None, str | None]:
    for path in brand_candidates(explicit):
        if not (path / ".git").exists():
            continue
        result = subprocess.run(["git", "-C", str(path), "show", f"{BRAND_COMMIT}:{BRAND_PATH}"],
                                capture_output=True)
        if result.returncode == 0:
            return result.stdout, str(path)
    return None, None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--brand", help="an omodachi-brand checkout")
    parser.add_argument("--require-brand", action="store_true",
                        help="fail when no omodachi-brand checkout is reachable")
    args = parser.parse_args()
    failures = []
    brand, where = brand_bytes(args.brand)
    if brand is not None and hashlib.sha256(brand).hexdigest() != TOKENS_SHA256:
        failures.append(f"{where}: {BRAND_COMMIT[:7]}:{BRAND_PATH} is not sha256 {TOKENS_SHA256[:12]}… (pin is stale)")
    if brand is None and args.require_brand:
        failures.append("no omodachi-brand checkout with the pinned commit was found")
    for name in COPIES:
        data = (ROOT / name).read_bytes()
        if hashlib.sha256(data).hexdigest() != TOKENS_SHA256:
            failures.append(f"{name}: differs from the pinned brand tokens (sha256 {hashlib.sha256(data).hexdigest()[:12]}…)")
        if brand is not None and data != brand:
            failures.append(f"{name}: differs from {BRAND_COMMIT[:7]}:{BRAND_PATH} in {where}")
    for name in GOLDEN:
        golden = json.loads((ROOT / name).read_text())
        if golden.get("brand_commit") != BRAND_COMMIT:
            failures.append(f"{name}: exported from {golden.get('brand_commit')}, pin is {BRAND_COMMIT}")
    for failure in failures:
        print("check_motion_tokens:", failure, file=sys.stderr)
    if not failures:
        how = f"and git show in {where}" if where else "(no brand checkout here: sha256 only)"
        print(f"check_motion_tokens: {len(COPIES)} copy, {len(GOLDEN)} golden file at brand {BRAND_COMMIT[:7]} {how}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
