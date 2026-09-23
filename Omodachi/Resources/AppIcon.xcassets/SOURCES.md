# Where the app icon comes from

`AppIcon.appiconset` is rendered, not drawn: `scripts/render_app_icon.py` reads
`omodachi-brand/concepts/v6-omodachi-symbol.svg` — the standalone o the brand
README names, and the same outline `DesignSystem/OmodachiSymbol.swift` draws —
and fills it on the brand's own two grounds (STORE-2 §1).

| File | Ground | Ink | Appearance |
|---|---|---|---|
| `AppIcon.png` | `#faf7f2` paper | `#292b28` | any |
| `AppIcon-dark.png` | `#202321` night | `#f5f2e9` | dark (iOS 18+) |
| `AppIcon-tinted.png` | `#000000` | `#ffffff` | tinted (iOS 18+) |

1024×1024, 8-bit RGB with no alpha channel, opaque to the corners. The 96-unit
symbol canvas is scaled ×7 and centred, so every 4-unit step of the outline is
28 px and the edges are exact. To redo them after the brand changes:

    python3 scripts/render_app_icon.py

This is a second rendering of our mark, which `MenuIconSyncTests` otherwise
forbids; it lives in its own catalog, apart from `Brand.xcassets` (the vendors'
marks), because App Store Connect takes an icon only as a raster image.
