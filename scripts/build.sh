#!/bin/bash
# Single entry point for generating, building and testing Omodachi.
#
# Build products never land in the repository: everything goes to
# $OMODACHI_DERIVED_DATA (default $TMPDIR/omodachi-ios-derived).
#
# Xcode 27 fails SwiftTerm's build-plugin validation, so every xcodebuild
# invocation carries -skipPackagePluginValidation -skipMacroValidation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Omodachi.xcodeproj"
SCHEME="Omodachi"
DERIVED="${OMODACHI_DERIVED_DATA:-${TMPDIR:-/tmp}/omodachi-ios-derived}"
FLAGS=(-skipPackagePluginValidation -skipMacroValidation)

# Destinations are never resolved by device name. A `name=` destination picks
# whatever simulator on this Mac happens to answer to that name, which on the
# maintainer's machine is a device other specs are using (INPUT-2 §6.5,
# MERGE-1 §2). Either an explicit destination is supplied, or this script
# creates its own simulators, addresses them by udid and deletes them when it
# exits.
IPHONE_DEVICE_TYPE="${OMODACHI_IPHONE_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}"
IPAD_DEVICE_TYPE="${OMODACHI_IPAD_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB}"
SIM_RUNTIME="${OMODACHI_SIM_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-27-0}"
# create_sim runs inside a command substitution, so the udids are recorded in a
# file rather than a shell array: a subshell could not tell the trap about them.
EPHEMERAL_SIM_LOG="$(mktemp "${TMPDIR:-/tmp}/omodachi-build-sims.XXXXXX")"

delete_ephemeral_sims() {
  local udid
  if [[ -s "$EPHEMERAL_SIM_LOG" ]]; then
    while read -r udid; do
      [[ -n "$udid" ]] || continue
      echo "==> deleting simulator $udid"
      xcrun simctl delete "$udid" >/dev/null 2>&1 || true
    done < "$EPHEMERAL_SIM_LOG"
  fi
  rm -f "$EPHEMERAL_SIM_LOG"
}
trap delete_ephemeral_sims EXIT

# create_sim <device type id> <label> -> prints the new udid
create_sim() {
  local device_type="$1" label="$2" udid
  udid="$(xcrun simctl create "omodachi-build-$label-$$-$RANDOM" "$device_type" "$SIM_RUNTIME")"
  printf '%s\n' "$udid" >> "$EPHEMERAL_SIM_LOG"
  printf '%s' "$udid"
}

# Resolves a destination for one of the two form factors. $1 is iphone|ipad.
destination_for() {
  case "$1" in
    iphone)
      if [[ -n "${OMODACHI_IPHONE_DESTINATION:-}" ]]; then
        printf '%s' "$OMODACHI_IPHONE_DESTINATION"
      else
        printf 'platform=iOS Simulator,id=%s' "$(create_sim "$IPHONE_DEVICE_TYPE" iphone)"
      fi
      ;;
    ipad)
      if [[ -n "${OMODACHI_IPAD_DESTINATION:-}" ]]; then
        printf '%s' "$OMODACHI_IPAD_DESTINATION"
      else
        printf 'platform=iOS Simulator,id=%s' "$(create_sim "$IPAD_DEVICE_TYPE" ipad)"
      fi
      ;;
  esac
}

# The build stamp every target carries: the git short sha and the minute the
# build started. Info.plist expands them into OmodachiBuildCommit and
# CFBundleVersion, and the Settings surface reads them back (Omodachi/BuildStamp.swift).
BUILD_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_TIME="$(date +%Y%m%d%H%M)"
STAMP=("OMODACHI_BUILD_COMMIT=$BUILD_COMMIT" "OMODACHI_BUILD_TIME=$BUILD_TIME")
# Simulator runs are native-arch only; the Moonlight vendor libraries ship no
# x86_64 simulator slice.
SIM_ARCHS=(ARCHS=arm64 ONLY_ACTIVE_ARCH=YES)

usage() {
  cat <<'USAGE'
usage: scripts/build.sh <command>

  generate      Regenerate Omodachi.xcodeproj from project.yml (xcodegen).
  build-sim     Debug build for the iPhone simulator.
  lint          The four-layer view lint (ARCH-1 §1) and the string-catalog
                check (I18N-1 §2), plus the lint's own self-test.
  test          lint, then the unit + UI suites on the iPhone and the iPad simulator.
  acceptance    One spec's operator suite against the real host, on the two
                simulators that spec named. Takes the condition and the class:
                  scripts/build.sh acceptance OMODACHI_ARCH1_ACCEPTANCE ARCH1AcceptanceTests
                Screenshots are exported from the result bundle into
                $OMODACHI_ACCEPTANCE_OUT (default $DERIVED/acceptance).
  build-device  Device build with signing disabled, for source verification.
  archive       Release archive for generic/platform=iOS with signing disabled
                (STORE-1 §2): catches what only the Release configuration
                trips — optimisation, `#if DEBUG` branches, type-check time —
                on a machine with no team. The .xcarchive lands in
                $OMODACHI_DERIVED_DATA/archive; it is not signed and cannot
                be uploaded.
  all           generate, build-sim, test, build-device.

Every build carries a stamp: CFBundleVersion is the build minute
(yyyymmddHHMM) and OmodachiBuildCommit is the git short sha. Settings shows
both as "build <sha> · <time>".

environment:
  OMODACHI_DERIVED_DATA        DerivedData path (default $TMPDIR/omodachi-ios-derived)
  OMODACHI_IPHONE_DESTINATION  xcodebuild -destination for the phone run
  OMODACHI_IPAD_DESTINATION    xcodebuild -destination for the tablet run
  OMODACHI_IPHONE_DEVICE_TYPE  simctl device type for the created phone simulator
  OMODACHI_IPAD_DEVICE_TYPE    simctl device type for the created tablet simulator
  OMODACHI_SIM_RUNTIME         simctl runtime for the created simulators

Without OMODACHI_*_DESTINATION this script creates its own simulators, uses
them by udid and deletes them on exit. It never selects a simulator by name,
so an unrelated device on this Mac is never booted or installed into.
USAGE
}

require_project() {
  [[ -d "$PROJECT" ]] || generate
}

generate() {
  command -v xcodegen >/dev/null || { echo "xcodegen not found (brew install xcodegen)" >&2; exit 1; }
  ( cd "$ROOT" && xcodegen generate )
}

build_sim() {
  require_project
  local iphone
  iphone="$(destination_for iphone)"
  echo "==> build-sim $iphone"
  xcodebuild build -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
    -destination "$iphone" -derivedDataPath "$DERIVED" "${FLAGS[@]}" \
    "${SIM_ARCHS[@]}" "${STAMP[@]}" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
}

# ARCH-1 §1. The four layers are a rule the compiler cannot state, so they are
# checked before the tests rather than reviewed by eye. Non-zero fails the run.
lint_views() {
  echo "==> lint_views"
  "$ROOT/scripts/lint_views.sh" --self-test
  "$ROOT/scripts/lint_views.sh"
  # I18N-1 §2. The lint proves nothing says a word outside the catalog; this
  # proves the catalog says every one of those words in both languages, and
  # that `ReasonText` maps every reason code the contracts name.
  echo "==> check_xcstrings"
  python3 "$ROOT/scripts/check_xcstrings.py"
  # REMOTE-5 §2. A UI test may only wait on a name the app can produce: a wait
  # on a deleted accessibility identifier can only time out, and a timeout
  # reads exactly like a broken feature (GEST-1 §6b).
  echo "==> check_ui_identifiers"
  python3 "$ROOT/scripts/check_ui_identifiers.py"
}

run_tests() {
  lint_views
  require_project
  local destination
  local -a destinations=()
  destinations+=("$(destination_for iphone)")
  destinations+=("$(destination_for ipad)")
  for destination in "${destinations[@]}"; do
    echo "==> test $destination"
    xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
      -destination "$destination" -derivedDataPath "$DERIVED" "${FLAGS[@]}" \
      "${SIM_ARCHS[@]}" "${STAMP[@]}"
  done
}

# An operator suite: compiled with its own condition, run on the two named
# simulators by udid, and its screenshot attachments exported afterwards.
#
# The destinations are NOT created here: an acceptance run has to happen on the
# devices the spec named, because those are the ones that hold a pairing with
# the real host. They come from OMODACHI_IPHONE_DESTINATION and
# OMODACHI_IPAD_DESTINATION, and the run refuses without them rather than
# quietly pairing a fresh simulator with somebody's machine.
acceptance() {
  local condition="${1:?usage: acceptance <SWIFT_CONDITION> <TestClass> [test names…]}"
  local class="${2:?usage: acceptance <SWIFT_CONDITION> <TestClass> [test names…]}"
  shift 2
  : "${OMODACHI_IPHONE_DESTINATION:?acceptance needs an explicit OMODACHI_IPHONE_DESTINATION}"
  : "${OMODACHI_IPAD_DESTINATION:?acceptance needs an explicit OMODACHI_IPAD_DESTINATION}"
  require_project
  local out="${OMODACHI_ACCEPTANCE_OUT:-$DERIVED/acceptance}"
  mkdir -p "$out"
  local -a only=()
  if [[ $# -eq 0 ]]; then
    only+=("-only-testing:OmodachiUITests/$class")
  else
    local name
    for name in "$@"; do only+=("-only-testing:OmodachiUITests/$class/$name"); done
  fi
  local label destination bundle
  for label in ${OMODACHI_ACCEPTANCE_DESTINATIONS:-ipad iphone}; do
    destination="$(destination_for "$label")"
    bundle="$out/$label.xcresult"
    rm -rf "$bundle"
    echo "==> acceptance $label $destination"
    xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
      -destination "$destination" -derivedDataPath "$DERIVED" "${FLAGS[@]}" \
      "${SIM_ARCHS[@]}" "${STAMP[@]}" "${only[@]}" \
      -resultBundlePath "$bundle" \
      OMODACHI_OPERATOR_SWIFT_CONDITION="$condition" || true
    rm -rf "$out/$label-attachments"
    xcrun xcresulttool export attachments --path "$bundle" \
      --output-path "$out/$label-attachments" >/dev/null 2>&1 || true
    echo "==> attachments: $out/$label-attachments"
  done
}

build_device() {
  require_project
  xcodebuild build -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" "${FLAGS[@]}" \
    "${STAMP[@]}" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
}

# STORE-1 §2. The archive the App Store build will be, minus the signature.
# The log is kept next to the archive so the warnings can be counted and read.
archive() {
  require_project
  local out="$DERIVED/archive" started ended status=0
  mkdir -p "$out"
  rm -rf "$out/Omodachi.xcarchive"
  started="$(date +%s)"
  xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$DERIVED" "${FLAGS[@]}" \
    -archivePath "$out/Omodachi.xcarchive" "${STAMP[@]}" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    2>&1 | tee "$out/archive.log" || status=$?
  ended="$(date +%s)"
  echo "==> archive: $out/Omodachi.xcarchive ($((ended - started)) s)"
  echo "==> warnings: $(grep -c ': warning: ' "$out/archive.log" || true) (log: $out/archive.log)"
  return "$status"
}

case "${1:-}" in
  generate) generate ;;
  lint) lint_views ;;
  build-sim) build_sim ;;
  test) run_tests ;;
  acceptance) shift; acceptance "$@" ;;
  build-device) build_device ;;
  archive) archive ;;
  all) generate; build_sim; run_tests; build_device ;;
  ""|-h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
