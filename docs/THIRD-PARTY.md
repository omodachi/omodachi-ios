# Third-party material shipped inside the app

Everything else the app draws with comes from the paired host at runtime: the
palette, alphas, sizes and type scale from `GET /v1/theme`, the monospace family
and Omarchy's private icon font from `GET /v1/fonts`
(`omodachi-core/docs/theme.md`, `docs/fonts.md`). This file lists what is in the
bundle instead.

## Fonts

### Symbols Nerd Font Mono

| | |
|---|---|
| File | `Omodachi/Resources/Fonts/SymbolsNerdFontMono-Regular.ttf` |
| Family / PostScript name | `Symbols Nerd Font Mono` / `SymbolsNFM` |
| Version | Nerd Fonts **v3.5.1** (`NerdFontsSymbolsOnly.zip`, archived 2025-08-21) |
| Origin | <https://github.com/ryanoasis/nerd-fonts/releases/tag/v3.5.1> |
| Size | 2 610 012 bytes (2.49 MiB) |
| sha256 | `fe471e538392f51910faab985fa8e192a39dd3426125edd15b71b3680df0e749` |
| Licence | **MIT** — nerd-fonts, Copyright (c) 2014 Ryan L McIntyre. Full text: `LICENSE` in the release archive, reproduced below. |

**Why it is here.** Omarchy's menu rows carry Nerd Font code points in their
`icon` field, but the host monospace family is whatever `fc-match monospace`
resolves to and is **not necessarily a Nerd Font** — the development host
resolves it to Nimbus Mono PS. `docs/fonts.md` is explicit that core does not
paper over that. So the body text stays the host's family and only the icon
code points fall back to this face, which carries symbols and no letterforms.

Rows tagged `"iconFont": "omarchy"` never use it: those are Omarchy's own
private-use code points and the set grows with every Omarchy release, so
`omarchy.ttf` is always fetched from the host.

The symbols-only build is used deliberately: a full patched family would be
tens of megabytes and would also supply letterforms, which would let the app
quietly stop using the host's font.

```
The MIT License (MIT)

Copyright (c) 2014 Ryan L McIntyre

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

### Removed: JetBrains Mono

`JetBrainsMono-Regular.ttf` and `JetBrainsMono-SemiBold.ttf` were bundled up to
SPEC-F2 and are gone. They were a client-side type decision, which SPEC-F2 §1
forbids: body text is the host's monospace family, and with no host reached yet
it is `.monospacedSystemFont`, not a family this repository chose.

## Vendor marks

Two panels are a window onto somebody else's product, and AGENT-2 gave them that
vendor's own mark instead of a generic glyph (Leo: "default agent 我们可以用官方
的图标么"). Both are **template** images: they are drawn in the host theme's
foreground and have no colour of their own, which is also the only form either
vendor's guidelines allow a third party to place the mark in.

### Codex (OpenAI)

| | |
|---|---|
| File | `Omodachi/Resources/Brand.xcassets/brand-codex.imageset/codex-mark.svg` |
| Origin | `openai/codex`, `codex-rs/login/src/assets/success.html` — the `<link rel="icon">` data URI (blob `eeeb5bc4e3b4`), percent-decoded and nothing else |
| Repository | <https://github.com/openai/codex> (Apache-2.0) |
| Size / sha256 | 397 bytes · `6e4e5b57faa8834042ef7c711967de1b3a90e08d7f9d3afc2f7f468c1c3a46f0` |
| Guidelines | <https://openai.com/brand/> |

The artwork is already a single stroked path with `fill="none"` and one stroke
colour, so monochrome is its published form rather than something done to it.
OpenAI's guidelines let third parties display the marks to refer to OpenAI
products, place the logomark in black or white and no other colour, and require
that it never appear more prominently than the product's own marks. Here it is
one 22-point glyph in a bar slot and one beside the agent's name, under
Omodachi's own logo; nothing claims a partnership.

### Herdr

| | |
|---|---|
| File | `Omodachi/Resources/Brand.xcassets/brand-herdr.imageset/herdr-mark.svg` |
| Origin | `herdrdev/herdr`, `assets/logo.svg` (blob `23057315093b`) |
| Repository | <https://github.com/herdrdev/herdr> (Apache-2.0) |
| Size / sha256 | 2 082 bytes · `e5f433fbd36c05a948f9e6c32ba25ab2d0803e3fe39ff157108ff26ae4300f50` |

Two edits and no others: the `#d9dad8` background plate is removed and the
drawing's `#303438` becomes `#000000`, because a template image takes its colour
from the theme. Apache-2.0 §6 grants no trademark licence, so this is
referential use — the mark identifies Herdr, which is what panel ④ talks to, and
is never used as a mark of Omodachi's own.

## Libraries

Dependency versions and why each one is here are in the root `README.md`.

This file is also bundled into the app (STORE-2 §4): Settings ⑥ → About →
Licence lists every row of the two tables below, read by
`Omodachi/Host/LicenceNotice.swift` from any table whose first header cell is
`Component` or `Package` and which has a `Licence` column. Keep that shape when
adding a row, and the app's list follows.
`Vendor/Moonlight/PATCHES.md` records every deviation from upstream Moonlight.

### Vendored in this repository

| Component | Path | Licence | Where that is stated |
| --- | --- | --- | --- |
| Moonlight iOS 9.0.2 | `Vendor/Moonlight/` | **GPL-3.0** | `Vendor/Moonlight/LICENSE.txt` |
| moonlight-common-c | `Vendor/Moonlight/common/` | **GPL-3.0** | `Vendor/Moonlight/common/LICENSE.txt` |
| ENet | `Vendor/Moonlight/common/enet/` | MIT | `Vendor/Moonlight/common/enet/LICENSE` |
| Reed-Solomon FEC | `Vendor/Moonlight/common/reedsolomon/` | BSD-2-Clause | the header of `rs.c`, Luigi Rizzo and Alain Knaff |
| SDL2 | `Vendor/Moonlight/libs/SDL2/` | zlib | `Vendor/Moonlight/libs/SDL2/LICENSE.txt` (upstream, release-2.28.5) |
| Opus | `Vendor/Moonlight/libs/opus/` | BSD-3-Clause | `Vendor/Moonlight/libs/opus/COPYING` (upstream, v1.4) |
| FFmpeg | `Vendor/Moonlight/libs/FFmpeg/` | LGPL-2.1-or-later | `Vendor/Moonlight/libs/FFmpeg/COPYING.LGPLv2.1` and `LICENSE.md` (upstream, `3f890fbfd9`) |
| LibVNCClient | `Vendor/LibVNCClient.xcframework/` | **GPL-2.0-or-later** | `Vendor/LibVNCClient.xcframework/LICENSE`; source and build in `BUILD.md` there |
| Symbols Nerd Font Mono | `Omodachi/Resources/Fonts/` | MIT | reproduced above |

### Corresponding source of the prebuilt binaries

Four vendored components arrive as compiled static libraries rather than
source. Each one's exact upstream source and build recipe is recorded:

| Binary | Upstream source | Build recipe | Record |
| --- | --- | --- | --- |
| `libvncclient.a` (both slices) | LibVNC/libvncserver tag `LibVNCServer-0.9.15`, commit `9b54b1ec3273`, archive sha256 `62352c77…d675d7` | `scripts/build_libvncclient.sh`: one-line change to `listen.c` (no fork on iOS), `-include unistd.h`, every optional dependency off | `Vendor/LibVNCClient.xcframework/BUILD.md` |
| `libavcodec.a`, `libavformat.a`, `libavutil.a` | FFmpeg commit `3f890fbfd9014843c51408c8f7ab3ba4aef7d354` (`N-112686-g3f890fbfd9`), LGPL build (no `--enable-gpl`) | cgutman/moonlight-mobile-deps `dad1ce6d964b`, `FFmpeg.sh`; configure line embedded in each archive | `Vendor/Moonlight/libs/PROVENANCE.md` |
| `libopus.a` | Opus 1.4 release tarball (tag `v1.4`), sha256 `c9b32b42…ce49c51f` | cgutman/moonlight-mobile-deps `02c97bc2e0b3`, `opus.sh` | `Vendor/Moonlight/libs/PROVENANCE.md` |
| `libSDL2.a` | SDL tag `release-2.28.5`, commit `15ead9a40d09` | cgutman/moonlight-mobile-deps `02c97bc2e0b3`, `SDL-ios.sh` | `Vendor/Moonlight/libs/PROVENANCE.md` |

How firm each line is:

- **LibVNCClient is reproduced.** Rebuilding with the script on 2026-09-25
  gave archive members byte-identical to the committed ones, both slices. It
  is upstream 0.9.15 plus the one-line change `BUILD.md` shows — not an
  unmodified upstream build.
- **SDL2, Opus and FFmpeg are identified, not reproduced.** The archives and
  headers are byte-identical to the ones in upstream Moonlight iOS 9.0.2
  (`85af0f7`), and the versions and build commits come from what the archives
  embed (FFmpeg's configure line and version, `libopus 1.4`, SDL's build
  paths) matched against moonlight-mobile-deps' history. They were built on
  AppVeyor with Xcode 14.1 and have not been rebuilt here.
  `Vendor/Moonlight/libs/Build.txt` is upstream Moonlight's note and names no
  commit; `PROVENANCE.md` beside it does.

FFmpeg is LGPL-2.1-or-later and is linked statically. LGPL-2.1 §6 is met by
the whole app being public source: a user can build FFmpeg from the source
above, replace the three archives and rebuild the app with
`scripts/build.sh` (`Vendor/Moonlight/libs/PROVENANCE.md` §4). SDL2 is zlib and
Opus is BSD-3-Clause; neither asks for relinking.

### Resolved by Swift Package Manager

Not in this tree. `Package.resolved` pins each one and the build fetches it.

| Package | Version | Licence |
| --- | --- | --- |
| [Citadel](https://github.com/orlandos-nl/Citadel) | 0.12.0 | MIT |
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.20.0 | MIT |
| [swift-nio-ssh](https://github.com/Joannis/swift-nio-ssh), Citadel's own maintainer fork | 0.3.5 | Apache-2.0 |
| swift-nio, swift-crypto, swift-asn1, swift-collections, swift-atomics, swift-log, swift-system, swift-argument-parser | pinned in `Package.resolved` | Apache-2.0 |
| [BigInt](https://github.com/attaswift/BigInt) | 5.7.0 | MIT |
| [OpenSSL-Package](https://github.com/krzyzanowskim/OpenSSL-Package) | 3.3.2000 | Apache-2.0, OpenSSL 3's own licence. That repository ships no licence file of its own; it repackages OpenSSL 3.3 |

### What that means for this repository

The two GPL components are linked into the one app binary. A distributed build
is therefore a combined work that has to be offered under **GPL-3.0**, the one
version both licences reach, and that is the licence in the root `LICENSE`.
Replacing Moonlight and LibVNCClient is the only way this repository gets a
free choice.

The same fact bears on TestFlight and the App Store. Apple's terms restrict
what a recipient may do with the binary in ways GPL-3.0 does not allow, and
that conflict has removed GPL apps from the store before. Where this stands
(2026-09-25):

- TestFlight is open to an internal testing group.
- Version 0.1.0 was submitted to App Store review on 2026-09-25. It is not
  live. Its licence agreement is a custom EULA carrying the GPL-3.0 text and
  naming this repository as the source.
- The maintainers of both GPL components were written to on 2026-09-25,
  asking for an additional permission for App Store distribution. **No such
  permission exists.** LibVNCServer's maintainer replied that he is not the
  sole copyright holder and so cannot grant or refuse one, and left the
  decision to us; that is not a permission. Moonlight has not replied.
- The App Store submission went ahead on that basis, at Omodachi's own risk:
  any copyright holder of Moonlight or LibVNCServer can ask Apple to remove
  the app.
