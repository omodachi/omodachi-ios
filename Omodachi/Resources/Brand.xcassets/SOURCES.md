# Where these two marks come from

Both are the vendor's own published artwork, taken from the vendor's own
repository, reduced to one colour and drawn as a template image so the theme's
foreground is the only colour they ever have (Study 01: icons are monochrome).

## `brand-codex`

`codex-mark.svg` is the Codex product mark, copied byte-for-byte out of the
favicon OpenAI ships in its own CLI:
`openai/codex`, `codex-rs/login/src/assets/success.html` — the `<link rel="icon">`
data URI, percent-decoding only. Repository: <https://github.com/openai/codex>,
licensed Apache-2.0. The mark is already a single-stroke drawing with no colour
of its own (`stroke="#000"`, `fill="none"`), so "monochrome" is its native form
rather than something done to it.

Usage rules checked: OpenAI's brand guidelines, <https://openai.com/brand/> —
third parties may display the marks to refer to OpenAI products, the logomark is
placed in white or black and in no other colour, and it must never be shown more
prominently than the product's own marks. Here it is a 22-point glyph in one bar
slot and beside the agent's own name, under Omodachi's own logo; it never
appears as Omodachi's mark and nothing claims a partnership.

## `brand-herdr`

`herdr-mark.svg` is `assets/logo.svg` from <https://github.com/herdrdev/herdr>
(Apache-2.0), with two edits and no others: the `#d9dad8` background plate is
removed and the drawing's `#303438` becomes `#000000`, because a template image
takes its colour from the theme. Apache-2.0 §6 grants no trademark licence, so
this is referential use: the mark identifies Herdr, the thing the panel talks to,
and is not used as a mark of Omodachi's own.
