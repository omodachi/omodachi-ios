# Prebuilt SDL2, Opus and FFmpeg — exact sources

`Build.txt` and `Build-OpenSSL.txt` are upstream Moonlight's own notes and are
kept verbatim. `Build.txt` names the build repository
(`github.com/cgutman/moonlight-mobile-deps`) but no commit, and no version of
any library. This file supplies both. It and the licence files listed at the
end are ours; everything else in this directory is upstream.

## 1. The binaries are upstream Moonlight's, unchanged

All 234 files under `libs/` other than the ones this file adds (the ten `.a`
archives and every header) are byte-identical — same git blob id — to
`libs/` in `moonlight-stream/moonlight-ios` at
`85af0f75622bb2636481afda8b0fc5cc33d5956e` (9.0.2, the commit in
`../provenance.json`). Checked 2026-09-25 with `git hash-object` against
`gh api repos/moonlight-stream/moonlight-ios/git/trees/85af0f7…?recursive=1`.
`../archive-sha256.json` holds the sha256 of each archive.

In moonlight-ios those archives were last replaced by:

| moonlight-ios commit | Date (UTC) | What |
|---|---|---|
| `ce25a66dc5` | 2023-11-04 06:08 | "Bump SDL to 2.28.5 and add FFmpeg for AV1 parsing" |
| `3ebcc86f0d` | 2023-11-04 08:15 | "Fix simulator builds and update to libopus v1.4" — last change to `libs/SDL2` and `libs/opus` |
| `c51caba1ec` | 2023-11-07 01:00 | "Rebuild FFmpeg with AV1 CBS compiled in" — last change to `libs/FFmpeg` |

## 2. Which moonlight-mobile-deps commit built them

The CI build logs (AppVeyor) are not available to us, so the commit is
identified from what the binaries themselves record, matched against the
build scripts in <https://github.com/cgutman/moonlight-mobile-deps>:

- **FFmpeg** — each `libav*.a` embeds its configure line and version:
  `FFmpeg version N-112686-g3f890fbfd9`, and
  `--enable-cross-compile --disable-all --disable-autodetect --disable-x86asm
  --enable-avcodec --enable-avformat --enable-muxer=flv --enable-decoder=av1`,
  built under `/Users/appveyor/projects/moonlight-mobile-deps/` with Xcode 14.1
  (iOS SDK 16.1), `-mios-version-min=12.0`. `--enable-decoder=av1` first
  appears in `FFmpeg.sh` at moonlight-mobile-deps
  **`dad1ce6d964b6d4cc61116f1b7170954eb08ef20`** (2023-11-06 18:12 −06:00,
  "Compile AV1 CBS code into the FFmpeg libraries"), whose `archive.sh` also
  copies the private `cbs.h`, `cbs_av1.h` and `av1.h` headers present here.
  moonlight-ios took the rebuild 48 minutes later (`c51caba1ec`). The FFmpeg
  submodule at that commit is `3f890fbfd9014843c51408c8f7ab3ba4aef7d354`,
  the commit the version string names.
- **Opus** — `libopus.a` embeds `libopus 1.4` and the build directory
  `/Users/appveyor/projects/moonlight-mobile-deps/opus-1.4`. Opus 1.4 was
  added at moonlight-mobile-deps `222dce4`; the next five commits fix its
  download and build, the last being
  **`02c97bc2e0b3a93394e7e9ba2b843e922c601e0c`** (2023-11-04 02:51 −05:00,
  "Try to fix preprocessor error on AppVeyor VM"), 24 minutes before
  moonlight-ios `3ebcc86f0d` (03:15 −05:00) took the Opus 1.4 archives.
  From `02c97bc` to `dad1ce6` the Opus build does not change: the official
  release tarball `opus-1.4.tar.gz`, `./configure --disable-shared
  --enable-static --with-pic --disable-extra-programs --disable-doc`,
  `-O3 -g`, minimum iOS 12.0, explicit `CPP` (`opus.sh`). Whether an earlier
  commit in `222dce4`…`41a7429` produced a successful build is not known
  without the CI logs; all of them use the same tarball and version.
- **SDL2** — the headers say 2.28.5 (`SDL_version.h`), and `libSDL2.a` embeds
  source paths under `/Users/appveyor/projects/moonlight-mobile-deps/SDL/`.
  The SDL submodule is `15ead9a40d09a1eb9972215cceac2bf29c9b77f6` (tag
  `release-2.28.5`) from moonlight-mobile-deps `9de341b` through `1554608`,
  built with SDL's own Xcode project, target `Static Library-iOS`,
  configuration Release (`SDL-ios.sh`). The simulator archive here keeps both
  arm64 and x86_64, which `SDL-ios.sh` does only from `c3292cf` ("Don't strip
  arm64 out of the simulator binaries") on, so the build moonlight-ios took is
  from `c3292cf`…`02c97bc`; the SDL source is the same tag throughout.

This is an identification from recorded evidence, not a reproduction: the
archives were built with Xcode 14.1 on AppVeyor and have not been rebuilt
here.

## 3. Upstream sources at those versions

| Library | Version | Source | Licence |
|---|---|---|---|
| FFmpeg (libavcodec, libavformat, libavutil) | git `3f890fbfd9014843c51408c8f7ab3ba4aef7d354` (2023-10-23, master; `N-112686-g3f890fbfd9`) | <https://github.com/FFmpeg/FFmpeg/tree/3f890fbfd9014843c51408c8f7ab3ba4aef7d354>, archive <https://github.com/FFmpeg/FFmpeg/archive/3f890fbfd9014843c51408c8f7ab3ba4aef7d354.tar.gz> | LGPL-2.1-or-later. Built without `--enable-gpl` or `--enable-nonfree`; each archive states `license: LGPL version 2.1 or later` |
| Opus | 1.4 (tag `v1.4`, commit `82ac57d9f1aaf575800cf17373348e45b7ce6c0d`) | <https://github.com/xiph/opus/releases/download/v1.4/opus-1.4.tar.gz>, sha256 `c9b32b4253be5ae63d1ff16eea06b94b5f0f2951b7a02aceef58e3a3ce49c51f` (matches `downloads.xiph.org/releases/opus/SHA256SUMS.txt`) | BSD-3-Clause, plus the royalty-free patent licences named in `COPYING` |
| SDL2 | 2.28.5 (tag `release-2.28.5`, commit `15ead9a40d09a1eb9972215cceac2bf29c9b77f6`) | <https://github.com/libsdl-org/SDL/tree/release-2.28.5> | zlib |
| Build scripts | moonlight-mobile-deps `dad1ce6d…` (FFmpeg), `02c97bc2…` (SDL2, Opus; identical to `dad1ce6` for both) | <https://github.com/cgutman/moonlight-mobile-deps/tree/dad1ce6d964b6d4cc61116f1b7170954eb08ef20> (`appveyor.yml`, `FFmpeg.sh`, `opus.sh`, `SDL-ios.sh`, `archive.sh`) | no licence file in that repository |

Licence texts, copied verbatim from those exact upstream commits on
2026-09-25:

| File | From |
|---|---|
| `FFmpeg/COPYING.LGPLv2.1` | FFmpeg `3f890fbfd9…`, `COPYING.LGPLv2.1` |
| `FFmpeg/LICENSE.md` | FFmpeg `3f890fbfd9…`, `LICENSE.md` |
| `opus/COPYING` | opus `v1.4`, `COPYING` |
| `SDL2/LICENSE.txt` | SDL `release-2.28.5`, `LICENSE.txt` |

## 4. FFmpeg is LGPL and statically linked: relinking

LGPL-2.1 §6 lets a program that is linked with the library be distributed
under its own terms only if the recipient can modify the library and relink
the program against the modified version. On iOS these are static archives
(`-lavcodec -lavformat -lavutil` in `project.yml`), so there is no shared
library to swap; for static linking §6(a) asks for the program in a form that
can be relinked.

Omodachi meets that by publishing everything: the app's complete source is
public under GPL-3.0 at <https://github.com/omodachi/omodachi-ios>, tagged per
release, and `scripts/build.sh` builds it. To relink with a modified FFmpeg, a
user builds FFmpeg from the source above with the configure line in §2 (or
runs moonlight-mobile-deps' `FFmpeg.sh`), replaces the three archives in
`libs/FFmpeg/lib/iOS` (and `iOS-Sim`) and the headers in `libs/FFmpeg/include`,
and rebuilds the app. The same works for Opus and SDL2, whose licences do not
require it. Installing the result on a device needs the user's own Apple
signing identity (a free Apple ID works for personal builds); that is an Apple
platform constraint, not something the app or its licence adds.

SDL2 (zlib) and Opus (BSD-3-Clause) carry no relinking requirement; their
obligations are the notices, which the licence files above satisfy.
