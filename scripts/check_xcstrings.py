#!/usr/bin/env python3
"""Every word the app says, in both languages, with nothing left over (I18N-1 §2).

`scripts/build.sh test` runs this before the suites. It reads the two string
catalogs and the two Swift files allowed to name a key, and fails on any of:

  1. a key `Strings.swift` asks for that the catalog does not hold — at runtime
     that falls back to the Swift `defaultValue`, so zh-Hans looks fine and
     **English silently shows Chinese**. Seven keys were in exactly this state
     before this script existed;
  2. a localization that is missing, empty, or in any state other than
     `translated` (`needs_review`, `new`, `stale`);
  3. a zh-Hans value that disagrees with the `defaultValue` written in Swift,
     which would mean two different Chinese sentences for one key depending on
     whether the catalog was found;
  4. a key in the catalog that no Swift file asks for;
  5. a reason code `omodachi-core/contracts` names that `ReasonText` does not
     map (`--contracts <path>`), which would reach a screen as a bare
     identifier.

Exit status is the number of findings, capped at 125. `--json` prints the same
findings as a machine-readable list.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

LANGUAGES = ("zh-Hans", "en")
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# `String(localized: "<key>", defaultValue: "<zh>")` is the only shape allowed.
CALL = re.compile(r'String\(localized:\s*"([^"]+)",\s*defaultValue:\s*"((?:[^"\\]|\\.)*)"\)')
# `\(a)` in a Swift interpolation is `%@` (or `%1$@`, `%2$@`, …) in the catalog.
SLOT = re.compile(r"\\\([a-z]\)")


def swift_keys(path: str) -> dict[str, str]:
    with open(path, encoding="utf-8") as handle:
        source = handle.read()
    return {key: value for key, value in CALL.findall(source)}


def expected_catalog_value(default_value: str) -> str:
    slots = SLOT.findall(default_value)
    if not slots:
        return default_value
    if len(slots) == 1:
        return SLOT.sub("%@", default_value)
    index = [0]

    def numbered(_match: re.Match[str]) -> str:
        index[0] += 1
        return "%%%d$@" % index[0]

    return SLOT.sub(numbered, default_value)


def unit(entry: dict, language: str) -> dict | None:
    return entry.get("localizations", {}).get(language, {}).get("stringUnit")


def check_catalog(path: str, declared: dict[str, str], label: str,
                  compare_default: bool) -> list[str]:
    findings: list[str] = []
    with open(path, encoding="utf-8") as handle:
        catalog = json.load(handle)
    strings = catalog.get("strings", {})

    for key, default_value in sorted(declared.items()):
        entry = strings.get(key)
        if entry is None:
            findings.append(f"{label}: {key} — asked for in Swift, missing from the catalog")
            continue
        for language in LANGUAGES:
            found = unit(entry, language)
            if found is None:
                findings.append(f"{label}: {key} [{language}] — no translation")
                continue
            if found.get("state") != "translated":
                findings.append(f"{label}: {key} [{language}] — state is {found.get('state')!r}, not 'translated'")
            if not (found.get("value") or "").strip():
                findings.append(f"{label}: {key} [{language}] — empty value")
        if compare_default:
            found = unit(entry, "zh-Hans") or {}
            expected = expected_catalog_value(default_value)
            if found.get("value") is not None and found["value"] != expected:
                findings.append(
                    f"{label}: {key} [zh-Hans] — catalog {found['value']!r} "
                    f"but Swift says {expected!r}")

    for key in sorted(set(strings) - set(declared)):
        findings.append(f"{label}: {key} — in the catalog, asked for by nothing")
    return findings


def check_info_plist(path: str, keys: set[str]) -> list[str]:
    findings: list[str] = []
    with open(path, encoding="utf-8") as handle:
        catalog = json.load(handle)
    strings = catalog.get("strings", {})
    for key in sorted(keys):
        entry = strings.get(key)
        if entry is None:
            findings.append(f"InfoPlist: {key} — the plist declares it, the catalog does not translate it")
            continue
        for language in LANGUAGES:
            found = unit(entry, language)
            if found is None or found.get("state") != "translated" or not (found.get("value") or "").strip():
                findings.append(f"InfoPlist: {key} [{language}] — not translated")
    return findings


# --- 5. the contract's reason codes -----------------------------------------

REMOTE_ERROR_ROW = re.compile(r"^\|\s*`([a-z][a-z0-9_]*)`\s*\|\s*[0-9/ -]+\s*\|")


def contract_codes(contracts: str) -> set[str]:
    """Every reason/error code the contracts name, read from the contracts."""
    codes: set[str] = set()

    # a. `enum` values on any field called reason / disabled_reason
    for base, _dirs, files in os.walk(contracts):
        for name in files:
            if not name.endswith(".schema.json"):
                continue
            with open(os.path.join(base, name), encoding="utf-8") as handle:
                document = json.load(handle)

            def walk(node: object, path: str) -> None:
                if isinstance(node, dict):
                    if "enum" in node and re.search(r"reason", path, re.I):
                        codes.update(v for v in node["enum"] if isinstance(v, str))
                    for key, value in node.items():
                        walk(value, f"{path}/{key}")
                elif isinstance(node, list):
                    for item in node:
                        walk(item, path)

            walk(document, "")

    # b. the error table in docs/remote-api.md, which is where the HTTP codes
    #    are enumerated — `http-error.schema.json` types `code` as a string.
    api = os.path.join(os.path.dirname(contracts), "docs", "remote-api.md")
    if os.path.exists(api):
        with open(api, encoding="utf-8") as handle:
            inside = False
            for line in handle:
                stripped = line.strip()
                if stripped.startswith("| Code ") and "Status" in stripped:
                    inside = True
                    continue
                if inside:
                    match = REMOTE_ERROR_ROW.match(stripped)
                    if match:
                        codes.add(match.group(1))
                    elif not stripped.startswith("|"):
                        inside = False
    return codes


def check_reason_codes(contracts: str, reason_text: str) -> list[str]:
    if not os.path.isdir(contracts):
        return []
    with open(reason_text, encoding="utf-8") as handle:
        source = handle.read()
    start = source.index("static let knownCodes")
    mapped = set(re.findall(r'"([a-z][a-z0-9_]*)":\s*\.[a-z]+', source[start:]))
    missing = sorted(contract_codes(contracts) - mapped)
    return [f"ReasonText: {code} — core names this reason, ReasonText.knownCodes does not"
            for code in missing]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--contracts", default=os.path.join(ROOT, "..", "omodachi-core", "contracts"),
                        help="omodachi-core/contracts; skipped when it is not there")
    parser.add_argument("--json", action="store_true")
    options = parser.parse_args()

    declared: dict[str, str] = {}
    for name in ("Strings.swift", "ReasonText.swift"):
        path = os.path.join(ROOT, "Omodachi/DesignSystem", name)
        for key, value in swift_keys(path).items():
            declared[key] = value

    findings = check_catalog(os.path.join(ROOT, "Omodachi/Resources/Localizable.xcstrings"),
                             declared, "Localizable", compare_default=True)

    with open(os.path.join(ROOT, "Omodachi/Info.plist"), encoding="utf-8") as handle:
        plist = handle.read()
    plist_keys = {key for key in re.findall(r"<key>([A-Za-z]+)</key>", plist)
                  if key.endswith("UsageDescription") or key in {"CFBundleDisplayName", "CFBundleName"}}
    findings += check_info_plist(os.path.join(ROOT, "Omodachi/Resources/InfoPlist.xcstrings"), plist_keys)

    findings += check_reason_codes(os.path.abspath(options.contracts),
                                   os.path.join(ROOT, "Omodachi/DesignSystem/ReasonText.swift"))

    if options.json:
        print(json.dumps(findings, ensure_ascii=False, indent=2))
    elif findings:
        for finding in findings:
            print(finding)
        print(f"\n{len(findings)} findings", file=sys.stderr)
    else:
        print(f"check_xcstrings: {len(declared)} keys, "
              f"{len(declared) * len(LANGUAGES)} translations, all translated")
    return min(len(findings), 125)


if __name__ == "__main__":
    sys.exit(main())
