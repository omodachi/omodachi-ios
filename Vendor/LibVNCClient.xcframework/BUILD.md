# LibVNCClient.xcframework — where it comes from and how to rebuild it

Licence: **GPL-2.0-or-later** (`LICENSE` next to this file is the GPLv2 text;
upstream's own copy is `COPYING` in the source archive below).

## Source

| | |
|---|---|
| Project | LibVNCServer / LibVNCClient, <https://github.com/LibVNC/libvncserver> |
| Tag | `LibVNCServer-0.9.15` |
| Commit | `9b54b1ec32731bd23158ca014dc18014db4194c3` (2024-12-22, "Update ChangeLog for 0.9.15") |
| Archive | <https://codeload.github.com/LibVNC/libvncserver/tar.gz/refs/tags/LibVNCServer-0.9.15> (same bytes at `https://github.com/LibVNC/libvncserver/archive/refs/tags/LibVNCServer-0.9.15.tar.gz`) |
| Archive sha256 | `62352c7795e231dfce044beb96156065a05a05c974e5de9e023d688d8ff675d7` (checked 2026-09-25) |
| Built part | the `vncclient` CMake target only (`src/libvncclient/*` plus `src/common/*` helpers); no server code |

## Changes from upstream

This is **not** an unmodified upstream build. Two things differ from a plain
CMake build of the tag, and both are in `scripts/build_libvncclient.sh`:

1. **One source change**, `src/libvncclient/listen.c`:

   ```diff
   -#ifdef WIN32
   +#if defined(WIN32) || defined(OMADACHI_IOS_NO_LISTEN_FORK)
   ```

   `listenForIncomingConnections()` (the viewer's reverse-connection "listen"
   mode) forks a child per incoming connection. iOS apps cannot fork, and
   Omodachi never uses that mode, so on iOS the function takes upstream's own
   "not implemented" branch. The macro is defined only for the iOS builds.
   The vendored `listen.c.o` has no reference to `_fork` or `_wait4`; the same
   file compiled from the unpatched source does.
2. **One compiler flag**, `-include unistd.h`. Upstream 0.9.15 calls `close`,
   `read`, `sleep`, `usleep` in several client files without including
   `<unistd.h>` on this configuration, and current clang makes implicit
   declarations an error. The flag only adds declarations; it changes no code.

The macro keeps the project's former misspelling (`OMADACHI`) because that is
what the vendored binary was compiled with; renaming it would change nothing
in the object code but would make the reproduction below harder to read.

## Build configuration

- CMake generator Ninja; `CMAKE_BUILD_TYPE` empty (no `-O`, no `-g`), as in
  the original build.
- `-DBUILD_SHARED_LIBS=OFF -DWITH_EXAMPLES=OFF -DWITH_TESTS=OFF` and
  `-DWITH_<X>=OFF` for ZLIB, LZO, JPEG, PNG, SDL, GTK, LIBSSHTUNNEL, GNUTLS,
  OPENSSL, SYSTEMD, GCRYPT, FFMPEG, TIGHTVNC_FILETRANSFER, WEBSOCKETS, SASL,
  XCB, QT.
- `CMAKE_SYSTEM_NAME=iOS`, `CMAKE_OSX_ARCHITECTURES=arm64`,
  `CMAKE_OSX_DEPLOYMENT_TARGET=17.0`, sysroot `iphoneos` and `iphonesimulator`.

What that means, and what the vendored binary shows independently:

| Feature | Evidence in the vendored framework |
|---|---|
| no zlib → no ZRLE / Zlib / Tight encodings | `LIBVNCSERVER_HAVE_LIBZ` undefined in `rfbconfig.h`; no `zrle`/`zlib`/`tight` objects in the archive |
| no JPEG / PNG | `LIBVNCSERVER_HAVE_LIBJPEG`, `_LIBPNG` undefined |
| no TLS | `LIBVNCSERVER_HAVE_GNUTLS`, `_LIBSSL` undefined; archive has `tls_none.c.o` |
| no gcrypt → bundled crypto | `LIBVNCSERVER_HAVE_LIBGCRYPT` undefined; `crypto_included.c.o`, `d3des.c.o`, `sha1.c.o` present |
| no SASL | `LIBVNCSERVER_HAVE_SASL` undefined; no `sasl.c.o` |
| LZO via bundled miniLZO | `LIBVNCSERVER_HAVE_LZO` undefined; `minilzo.c.o` present |
| IPv6, pthreads | `LIBVNCSERVER_IPv6 1`, `LIBVNCSERVER_HAVE_LIBPTHREAD 1` |
| version | `LIBVNCSERVER_PACKAGE_STRING "LibVNCServer 0.9.15"` |
| target | every object: `LC_BUILD_VERSION` platform 2 (iOS) / 7 (iOS Simulator), minos 17.0, sdk 27.0 |

Archive members (both slices): `cursor.c.o listen.c.o rfbclient.c.o sockets.c.o
vncviewer.c.o sockets.c.o crypto_included.c.o sha1.c.o d3des.c.o tls_none.c.o
minilzo.c.o` (the second `sockets.c.o` is `src/common/sockets.c`); 108 exported
symbols.

`Headers/rfb/` is upstream `include/rfb/` unchanged (including the unused
`rfbconfig.h.cmakein` template) plus the `rfbconfig.h` CMake generated.

## Rebuild

```sh
scripts/build_libvncclient.sh --compare            # build in $TMPDIR, compare with this framework
scripts/build_libvncclient.sh --install            # replace this framework with the rebuild
```

Needs Xcode, `cmake` and `python3`. `ninja` comes from `PATH`, or the script
puts `ninja==1.13.2` in a throwaway venv inside its work directory. Nothing is
installed globally.

## Reproduction result (2026-09-25)

Rebuilt from a fresh download with Xcode 27.0 (27A266a), cmake 4.4.3,
ninja 1.13.2 on the maintainer's Mac:

- the tarball matched the sha256 above;
- **every archive member of both slices is byte-identical** to the committed
  `libvncclient.a` (12 members each, including the symbol table), and the
  exported symbol lists and `Headers/` are identical;
- the whole `.a` files differ only in the ar member headers, which record the
  build time (the committed ones say 2026-09-17 18:27 AEST);
- `Info.plist` differs only in the order of its two library entries.

So the committed binary is exactly LibVNCServer-0.9.15 plus the listen.c
change and flag above — no more and no less — built with this Xcode.

## History

The framework was produced on 2026-09-17, before the current team, by
`Tools/VNCRemoteTests/build_dependency.py` (in the baseline commit `1763850`,
removed in `afa7a61`). That script's working directory in `/tmp` has since
been emptied, so the original archive and build logs are gone. This file and
`scripts/build_libvncclient.sh` replace it; the reproduction above is what
ties them to the committed bytes.
