#!/bin/bash
# Rebuild Vendor/LibVNCClient.xcframework from pinned upstream source.
#
# Upstream:  https://github.com/LibVNC/libvncserver, tag LibVNCServer-0.9.15
#            (commit 9b54b1ec32731bd23158ca014dc18014db4194c3, 2024-12-22)
# Archive:   GitHub's tag tarball, sha256 checked below. The same bytes are
#            served by codeload.github.com and github.com/.../archive/.
# Licence:   GPL-2.0-or-later (upstream COPYING; copy in the xcframework).
#
# This is the recipe the vendored binary was produced with. It was first
# written as Tools/VNCRemoteTests/build_dependency.py (baseline commit 1763850,
# 2026-09-18; the file was removed in afa7a61). This script performs the same
# steps: the same archive, the same one-line source change, the same CMake
# options and compiler flags. Vendor/LibVNCClient.xcframework/BUILD.md records
# how the rebuilt output compares with the committed binary.
#
# Usage:
#   scripts/build_libvncclient.sh [--work DIR] [--install] [--compare]
#
#   --work DIR  scratch directory (default: $TMPDIR/omodachi-libvncclient).
#               Everything is written there; nothing outside it is touched
#               unless --install is given.
#   --install   replace Vendor/LibVNCClient.xcframework with the rebuilt one
#               (LICENSE and BUILD.md are carried over).
#   --compare   compare the rebuilt static libraries with the vendored ones:
#               every archive member byte for byte (the ar member headers
#               carry the build time and are skipped), exported symbols,
#               and the headers.
#
# Needs: Xcode (xcodebuild, xcrun, clang), cmake >= 3.5, python3, curl.
# ninja is taken from PATH; if it is missing, a throwaway venv inside the work
# directory gets `pip install ninja==1.13.2` (the version the original build
# used). Nothing is installed globally.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDORED="$ROOT/Vendor/LibVNCClient.xcframework"

TAG="LibVNCServer-0.9.15"
COMMIT="9b54b1ec32731bd23158ca014dc18014db4194c3"
URL="https://codeload.github.com/LibVNC/libvncserver/tar.gz/refs/tags/$TAG"
SHA256="62352c7795e231dfce044beb96156065a05a05c974e5de9e023d688d8ff675d7"
DEPLOYMENT_TARGET="17.0"

WORK="${TMPDIR:-/tmp}/omodachi-libvncclient"
INSTALL=0
COMPARE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --work) WORK="$2"; shift 2 ;;
    --install) INSTALL=1; shift ;;
    --compare) COMPARE=1; shift ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"

# --- tools -------------------------------------------------------------------
for tool in cmake xcodebuild xcrun curl python3 shasum patch; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
NINJA="$(command -v ninja || true)"
if [ -z "$NINJA" ]; then
  if [ ! -x "$WORK/venv/bin/ninja" ]; then
    python3 -m venv "$WORK/venv"
    "$WORK/venv/bin/pip" install --quiet ninja==1.13.2
  fi
  NINJA="$WORK/venv/bin/ninja"
fi
echo "cmake:  $(cmake --version | head -1)"
echo "ninja:  $("$NINJA" --version) ($NINJA)"
echo "xcode:  $(xcodebuild -version | tr '\n' ' ')"

# --- source ------------------------------------------------------------------
ARCHIVE="$WORK/$TAG.tar.gz"
[ -f "$ARCHIVE" ] || curl -fsSL -o "$ARCHIVE" "$URL"
got="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [ "$got" != "$SHA256" ]; then
  echo "archive sha256 mismatch: $got (want $SHA256)" >&2
  exit 1
fi
SOURCE="$WORK/libvncserver-$TAG"
rm -rf "$SOURCE"
tar -xzf "$ARCHIVE" -C "$WORK"

# The one source change. iOS has no fork(), and the client's reverse-listen
# mode (listenForIncomingConnections) forks per connection. Omodachi never uses
# that mode, so on iOS the function takes upstream's own WIN32 "not
# implemented" branch. Guarded by a macro only the iOS builds define.
(cd "$SOURCE" && patch -p1 --no-backup-if-mismatch --quiet) <<'PATCH'
--- a/src/libvncclient/listen.c
+++ b/src/libvncclient/listen.c
@@ -48,7 +48,7 @@
 void
 listenForIncomingConnections(rfbClient* client)
 {
-#ifdef WIN32
+#if defined(WIN32) || defined(OMADACHI_IOS_NO_LISTEN_FORK)
   /* FIXME */
   rfbClientErr("listenForIncomingConnections on MinGW32 NOT IMPLEMENTED\n");
   return;
PATCH

# --- build -------------------------------------------------------------------
# Every optional dependency is off: no zlib (so no ZRLE/Tight/Zlib encodings),
# no JPEG/PNG, no TLS (tls_none.c), no SASL, no gcrypt (the bundled
# crypto_included.c/d3des.c/sha1.c are used), LZO via the bundled minilzo.c.
# CMAKE_BUILD_TYPE is deliberately left empty, as in the original build.
# The macro name keeps the project's former spelling (OMADACHI) because that
# is what the vendored binary was compiled with.
COMMON=(
  -G Ninja "-DCMAKE_MAKE_PROGRAM=$NINJA"
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
  -DBUILD_SHARED_LIBS=OFF -DWITH_EXAMPLES=OFF -DWITH_TESTS=OFF
)
for x in ZLIB LZO JPEG PNG SDL GTK LIBSSHTUNNEL GNUTLS OPENSSL SYSTEMD GCRYPT \
         FFMPEG TIGHTVNC_FILETRANSFER WEBSOCKETS SASL XCB QT; do
  COMMON+=("-DWITH_$x=OFF")
done

build_slice() { # $1 name, $2 sdk
  local build="$WORK/build-$1" headers="$WORK/headers-$1"
  rm -rf "$build" "$headers"
  cmake -S "$SOURCE" -B "$build" "${COMMON[@]}" \
    "-DCMAKE_C_FLAGS=-include unistd.h -DOMADACHI_IOS_NO_LISTEN_FORK" \
    -DCMAKE_SYSTEM_NAME=iOS "-DCMAKE_OSX_SYSROOT=$2" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    "-DCMAKE_OSX_DEPLOYMENT_TARGET=$DEPLOYMENT_TARGET" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY >"$WORK/$1.log" 2>&1
  cmake --build "$build" --target vncclient -j4 >>"$WORK/$1.log" 2>&1
  mkdir -p "$headers"
  cp -R "$SOURCE/include/rfb" "$headers/rfb"
  cp "$build/include/rfb/rfbconfig.h" "$headers/rfb/rfbconfig.h"
}
build_slice sim iphonesimulator
build_slice device iphoneos

OUT="$WORK/LibVNCClient.xcframework"
rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$WORK/build-sim/libvncclient.a" -headers "$WORK/headers-sim" \
  -library "$WORK/build-device/libvncclient.a" -headers "$WORK/headers-device" \
  -output "$OUT" >/dev/null
echo "built:  $OUT"
echo "source: $TAG ($COMMIT), archive sha256 $SHA256"

# --- compare -----------------------------------------------------------------
if [ "$COMPARE" = 1 ]; then
  python3 - "$VENDORED" "$OUT" <<'PY'
import hashlib, pathlib, subprocess, sys
vend, new = map(pathlib.Path, sys.argv[1:3])

def members(path):
    """(name, bytes) for every member of a BSD ar archive, duplicates kept
    (libvncclient has two sockets.c.o). The 60-byte member headers carry an
    mtime and are not part of the result."""
    b = path.read_bytes()
    assert b[:8] == b"!<arch>\n", path
    i, out = 8, []
    while i < len(b):
        h = b[i:i + 60]
        name, size = h[:16].decode().strip(), int(h[48:58])
        data = b[i + 60:i + 60 + size]
        if name.startswith("#1/"):
            n = int(name[3:])
            name, data = data[:n].rstrip(b"\0").decode(), data[n:]
        out.append((name, data))
        i += 60 + size + (size & 1)
    return out

def exported(path):
    out = subprocess.run(["nm", "-gU", str(path)], capture_output=True,
                         text=True, check=True).stdout
    return sorted(l.split()[-1] for l in out.splitlines()
                  if len(l.split()) >= 3 and not l.endswith(":"))

ok = True
for sl in ("ios-arm64", "ios-arm64-simulator"):
    a, b = vend / sl / "libvncclient.a", new / sl / "libvncclient.a"
    ma, mb = members(a), members(b)
    print(f"== {sl}")
    names = [n for n, _ in ma] == [n for n, _ in mb]
    ok &= names
    print(f"  member list       {'same' if names else 'DIFFERENT'} ({len(ma)} / {len(mb)})")
    for (na, da), (nb, db) in zip(ma, mb):
        same = da == db
        ok &= same
        print(f"    {na:22} {len(da):7} {len(db):7}  {'identical' if same else 'DIFFERENT'}")
    ea, eb = exported(a), exported(b)
    ok &= ea == eb
    print(f"  exported symbols  {'same' if ea == eb else 'DIFFERENT'} ({len(ea)} / {len(eb)})")
    print(f"  file size         vendored {a.stat().st_size}, rebuilt {b.stat().st_size}")
    whole = hashlib.sha256(a.read_bytes()).digest() == hashlib.sha256(b.read_bytes()).digest()
    print(f"  whole-file sha256 {'identical' if whole else 'differs (ar member headers hold the build time)'}")
    r = subprocess.run(["diff", "-r", str(vend / sl / "Headers"), str(new / sl / "Headers")],
                       capture_output=True, text=True)
    ok &= r.returncode == 0
    print(f"  headers           {'same' if r.returncode == 0 else 'DIFFERENT'}")
    if r.returncode:
        print(r.stdout[:2000])
print("RESULT:", "every archive member and header byte-identical" if ok else "NOT identical")
sys.exit(0 if ok else 1)
PY
fi

# --- install -----------------------------------------------------------------
if [ "$INSTALL" = 1 ]; then
  for keep in LICENSE BUILD.md; do
    [ -f "$VENDORED/$keep" ] && cp "$VENDORED/$keep" "$OUT/$keep"
  done
  rm -rf "$VENDORED"
  cp -R "$OUT" "$VENDORED"
  echo "installed into $VENDORED"
fi
