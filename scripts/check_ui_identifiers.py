#!/usr/bin/env python3
"""REMOTE-5 §2. A UI test may only wait on a name the app can actually produce.

GEST-1 §6b reported "the first frame never arrived" twice against a host that
was streaming the whole time. The suite was waiting 150 seconds for
`remote-edge-strip`, an accessibility identifier MERGE-1's A-40 had deleted
from the product months of specs earlier. A wait on a name nothing emits can
only time out, and a timeout reads exactly like a broken feature — so this is
checked rather than reviewed by eye.

The rule: every accessibility identifier a UI test reaches for
(`app.buttons["…"]`, `matching(identifier: "…")`, …) has to be producible by
some string literal under `Omodachi/`. Literals with interpolation
(`"remote-start-\\(kind.rawValue)"`) match anything in the interpolated slot,
so a name that is built at runtime still counts.

An identifier the product genuinely no longer has must be written down in
`OmodachiUITests/RETIRED-IDENTIFIERS.md` — which name, which surface took it
away, and what a test should reach for instead. Listing one is not a repair; it
is the record that this suite is asserting against something that is not there,
so the next person meets the fact instead of a 150-second timeout. Whether a
particular use is a legitimate "this must not be on screen" cannot be decided
from the text of one line, so it is not guessed at here: the file says it.

Exit 0 when clean, 1 with a list otherwise.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PRODUCT = ROOT / "Omodachi"
TESTS = ROOT / "OmodachiUITests"
RETIRED_DOC = TESTS / "RETIRED-IDENTIFIERS.md"

# A Swift string literal, with `\(…)` segments allowed inside it.
LITERAL = re.compile(r'"((?:[^"\\\n]|\\\([^()]*\))+)"')
INTERPOLATION = re.compile(r"\\\([^()]*\)")
# What a UI test reaches for. Identifiers only: a lowercase, dash-joined name.
# `buttons["确定"]` is a *label* lookup and is none of this script's business.
IDENT = r"[a-z][a-z0-9]*(?:-[a-z0-9]+)+"
USES = [
    re.compile(r'(?:buttons|staticTexts|otherElements|images|textFields|cells)\["(' + IDENT + r')"\]'),
    re.compile(r'matching\(identifier: "(' + IDENT + r')"\)'),
    re.compile(r'descendants\(matching: \.any\)\.matching\(identifier: "(' + IDENT + r')"\)'),
]

def product_names() -> tuple[set[str], list[re.Pattern[str]]]:
    plain: set[str] = set()
    patterns: list[re.Pattern[str]] = []
    for path in sorted(PRODUCT.rglob("*.swift")):
        for match in LITERAL.finditer(path.read_text(encoding="utf-8")):
            value = match.group(1)
            if "\\(" not in value:
                plain.add(value)
                continue
            # A literal that is nothing but interpolation ("\(a)-\(b)") would
            # match every name there is and turn this check off. Only patterns
            # with real text in them are allowed to stand in for a name.
            static = INTERPOLATION.sub("", value)
            if len(static) < 4:
                continue
            body = re.escape(INTERPOLATION.sub("\x00", value)).replace("\x00", r"[A-Za-z0-9_.\-]+")
            patterns.append(re.compile("^" + body + "$"))
    return plain, patterns


def retired() -> set[str]:
    if not RETIRED_DOC.exists():
        return set()
    names = set()
    for line in RETIRED_DOC.read_text(encoding="utf-8").splitlines():
        if not line.startswith("|"):
            continue
        # The first cell of a row, which may name several identifiers that went
        # away together.
        cell = line.split("|")[1]
        names.update(re.findall(r"`([^`]+)`", cell))
    return names


def main() -> int:
    plain, patterns = product_names()
    listed = retired()

    def producible(name: str) -> bool:
        return name in plain or any(p.match(name) for p in patterns)

    unknown: dict[str, set[str]] = {}
    for path in sorted(TESTS.rglob("*.swift")):
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for pattern in USES:
                for match in pattern.finditer(line):
                    name = match.group(1)
                    if producible(name):
                        continue
                    if name in listed:
                        continue
                    unknown.setdefault(name, set()).add(f"{path.name}:{number}")

    if not unknown:
        total = len(plain) + len(patterns)
        print(f"check_ui_identifiers: {total} product names, {len(listed)} retired, no stale waits")
        return 0

    for name, places in sorted(unknown.items()):
        print(f"no view produces {name!r}: {', '.join(sorted(places))}", file=sys.stderr)
    print("", file=sys.stderr)
    print(f"Point the test at a name the app emits, or write the name down in "
          f"{RETIRED_DOC.relative_to(ROOT)} with what took it away.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
