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
| SDL2 | `Vendor/Moonlight/libs/SDL2/` | zlib | `Vendor/Moonlight/libs/SDL2/include/SDL_copying.h` |
| Opus | `Vendor/Moonlight/libs/opus/` | BSD-3-Clause | the header of `include/opus/opus.h` |
| FFmpeg | `Vendor/Moonlight/libs/FFmpeg/` | LGPL-2.1-or-later | the header of `include/libavcodec/avcodec.h` |
| LibVNCClient | `Vendor/LibVNCClient.xcframework/` | **GPL-2.0-or-later** | the header notice in `Headers/rfb/rfbclient.h`; full text now vendored at `Vendor/LibVNCClient.xcframework/LICENSE` |
| Symbols Nerd Font Mono | `Omodachi/Resources/Fonts/` | MIT | reproduced above |

Opus, FFmpeg and SDL2 arrive as prebuilt static libraries, built from
`github.com/cgutman/moonlight-mobile-deps` as `Vendor/Moonlight/libs/Build.txt`
records. Their own licence texts are not in this tree; the headers that are
carry the notices the table cites.

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
that conflict has removed GPL apps from the store before. TestFlight is not
open, and this has to be resolved before the first build goes out.
