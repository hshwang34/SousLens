# Umma brand kit

Direction C, "Persimmon" (brief 013, DECISIONS #23). The exploration that led here is in
`umma-directions.html`; this folder holds the final masters.

Persimmons (감) are the fruit mums hand you in autumn. The mark is one, side-on, with its
four-leaf calyx. The wordmark is a lowercase "umma" in Bagel Fat One, a chunky Korean display face.

## Files

| File | What it is | Use it for |
| --- | --- | --- |
| `umma-mark.svg` | The persimmon, full colour | App surfaces, social avatars, anywhere the mark stands alone on a light background |
| `umma-mark-dark.svg` | The persimmon, tuned for dark backgrounds | The same, on Seed or any dark background |
| `umma-mark-mono.svg` | One colour (`currentColor`) | Embossing, single-ink print, watermarks, the iOS tinted icon reference |
| `favicon.svg` | The mark without its highlight | Browser tab, bookmarks (the highlight muddies at 16 px) |
| `umma-wordmark.svg` / `-dark.svg` | "umma", outlined to paths, in Leaf | Where the mark is already nearby (a nav bar next to the app icon, a footer) |
| `umma-lockup-horizontal.svg` / `-dark.svg` | Mark + wordmark | **The default.** Website header, decks, the README, store artwork |
| `umma-lockup-korean.svg` / `-dark.svg` | Mark + wordmark + 엄마 | Brand moments that tell the origin story: the website hero, the About screen, launch posts |
| `tools/umma-brand.swift` | The generator | Regenerating everything here, plus the app icon and the in-app `BrandMark` asset |
| `previews/` | Renders for review | Not for use |

Every file is generated. Don't edit the SVGs by hand: change the geometry or colours in
`tools/umma-brand.swift` and run it from the repo root.

```bash
swift docs/brand/tools/umma-brand.swift
```

It writes the SVG masters here, `AppIcon-{light,dark,tinted}.png` (1024 px) into
`ios/Umma/Resources/Assets.xcassets/AppIcon.appiconset`, the `BrandMark` vector imageset, and
`previews/app-icon-variants.png`. It uses only CoreGraphics and CoreText (macOS 13+), and reads the
font from `ios/Umma/Resources/Fonts/BagelFatOne-Regular.ttf`.

## Which lockup

- **Horizontal** is the default whenever there's room for the name.
- **Korean** (with 엄마) is for moments that tell the story of the name. It needs about 1.3× the
  height of the horizontal lockup, so skip it in tight headers.
- **Mark alone** when the name is already on screen or the space is square (app icon, avatar,
  favicon, the launch screen).
- **Wordmark alone** only when the mark is already visible nearby. Never pair the wordmark with a
  different symbol.

## Clear space and minimum size

- **Clear space:** keep at least the height of the calyx (about a quarter of the mark's height)
  free on every side. Nothing else, text included, goes inside it.
- **Minimum size:**
  - Mark: 16 px (favicon) and 29 pt (the iOS Settings icon). Below 24 px, use `favicon.svg`.
  - Horizontal lockup: 24 px tall.
  - Korean lockup: 40 px tall, so 엄마 stays legible.
- Don't stretch, rotate, outline, add drop shadows to, or recolour the mark outside the palette.
  Don't set "umma" in another typeface, and don't capitalise it in the logo. In running text
  the product is "Umma".

## Colour

| Name | Hex | Role |
| --- | --- | --- |
| **Persimmon** | `#F2782A` | The fruit. Fills: the primary button, illustration. Icons on light backgrounds use the deep persimmon token (`#B04A12`), since Persimmon is only 2.5:1 |
| **Leaf** | `#2F6B3A` | The calyx and wordmark. Links, tint, chips, accent **text** |
| **Flesh** | `#FFF1E6` | The app's light background |
| **Seed** | `#2A1C14` | Body text, and text on a Persimmon fill |
| Persimmon deep | `#D85F17` | 엄마 in the lockup only |
| Dark variants | `#FF8A3D` fruit, `#8ED39A` leaf | The mark and wordmark on dark backgrounds |

**Contrast rules.** Persimmon is a fill colour, not a text colour on light backgrounds: it is
2.5:1 on Flesh and 2.8:1 on white, which fails AA for body text (4.5:1) and even for large
text (3:1). On a Persimmon fill, set labels in **Seed** (5.9:1), never white (2.8:1). Leaf is
6.4:1 on white and 5.8:1 on Flesh, so it's the brand colour for text. Logos are exempt from WCAG
contrast, which is why the wordmark can be Leaf on Persimmon in a pinch, but text never can.

The app's full token table (light, dark and Increase Contrast) lives in
`ios/Umma/DesignSystem/Colors.swift` and is checked by `BrandTokenTests`.

## Type

- **Bagel Fat One** (SIL OFL 1.1, `ios/Umma/Resources/Fonts/BagelFatOne-OFL.txt`): the
  wordmark and large display titles only. It covers Hangul, so 엄마 and Korean recipe titles set
  in it too.
- **SF Pro** for everything else in the app; **SF Rounded** for quantities, timers and step
  numbers. The website pairs Bagel Fat One with Nunito.

## App icon

Built from the mark, 1024 px, in the three iOS 18 appearances:

- **Light:** the colour mark (Persimmon fruit, Leaf calyx) on a pale Flesh tile with a soft
  vertical gradient. The PM chose this over direction C's cream-fruit-on-orange tile because it
  reads literally as a persimmon.
- **Dark:** transparent background (iOS draws its dark backdrop), with the fruit itself in
  Persimmon and a light Leaf calyx.
- **Tinted:** grayscale on transparent, per Apple's guidance. The fruit is near-white and the
  calyx mid-grey, with a cut-out gap between them so they stay apart once iOS applies the tint.
