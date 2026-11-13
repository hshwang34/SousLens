#!/usr/bin/env swift
// Umma brand generator (brief 013, DECISIONS #23). The persimmon mark's geometry below is the
// single source of truth: every SVG master in docs/brand/, the in-app BrandMark asset and the
// three App Store icon PNGs are generated from it. The wordmark is Bagel Fat One (OFL), outlined
// to paths with CoreText so the SVGs need no font.
//
//   swift docs/brand/tools/umma-brand.swift            # from the repo root
//
// Needs macOS 13+ (CGPath boolean operations). No third-party tools.
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Paths and palette

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let brandDir = root.appendingPathComponent("docs/brand")
let previewDir = brandDir.appendingPathComponent("previews")
let assets = root.appendingPathComponent("ios/Umma/Resources/Assets.xcassets")
let fontURL = root.appendingPathComponent("ios/Umma/Resources/Fonts/BagelFatOne-Regular.ttf")

enum Brand {
    static let persimmon: UInt32 = 0xF2782A
    static let persimmonLight: UInt32 = 0xFF9A55   // highlight on the fruit
    static let persimmonDeep: UInt32 = 0xD85F17    // 엄마 in the lockup
    static let persimmonDark: UInt32 = 0xFF8A3D    // the fruit on dark backgrounds
    static let leaf: UInt32 = 0x2F6B3A
    static let leafDark: UInt32 = 0x8ED39A         // calyx / wordmark on dark backgrounds
    static let flesh: UInt32 = 0xFFF1E6
    static let seed: UInt32 = 0x2A1C14
}

func hex(_ value: UInt32) -> String { String(format: "#%06X", value) }

func cg(_ value: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

// MARK: - The mark (100 × 100 artboard, y down)

/// A broad sepal with a rounded tip, from `base` to `tip`. `width` is the half-width at its widest;
/// `bend` pushes the midline sideways so the sepal curls instead of sitting dead straight.
func sepal(from base: CGPoint, to tip: CGPoint, width: CGFloat, bend: CGFloat = 0) -> CGPath {
    let dx = tip.x - base.x, dy = tip.y - base.y
    let length = (dx * dx + dy * dy).squareRoot()
    let (ux, uy) = (dx / length, dy / length)       // along
    let (nx, ny) = (-uy, ux)                        // across
    func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
        let curl = bend * sin(.pi * along)
        return CGPoint(x: base.x + ux * along * length + nx * (across + curl),
                       y: base.y + uy * along * length + ny * (across + curl))
    }
    let path = CGMutablePath()
    path.move(to: point(0, width * 0.35))
    path.addCurve(to: point(1, 0), control1: point(0.45, width * 1.25), control2: point(0.98, width * 0.75))
    path.addCurve(to: point(0, -width * 0.35), control1: point(0.98, -width * 0.75), control2: point(0.45, -width * 1.25))
    path.closeSubpath()
    return path
}

enum Mark {
    /// Where the calyx sits on the fruit's shoulder.
    static let crown = CGPoint(x: 50, y: 37)

    /// A squat Fuyu persimmon seen from the side: wide shoulders, a shallow dip under the calyx,
    /// a full, slightly square base.
    static let fruit: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 50, y: 37.5))
        p.addCurve(to: CGPoint(x: 88, y: 50), control1: CGPoint(x: 64, y: 33), control2: CGPoint(x: 84, y: 34.5))
        p.addCurve(to: CGPoint(x: 76, y: 85.5), control1: CGPoint(x: 92.5, y: 64), control2: CGPoint(x: 88, y: 79))
        p.addCurve(to: CGPoint(x: 24, y: 85.5), control1: CGPoint(x: 64, y: 91.5), control2: CGPoint(x: 36, y: 91.5))
        p.addCurve(to: CGPoint(x: 12, y: 50), control1: CGPoint(x: 12, y: 79), control2: CGPoint(x: 7.5, y: 64))
        p.addCurve(to: CGPoint(x: 50, y: 37.5), control1: CGPoint(x: 16, y: 34.5), control2: CGPoint(x: 36, y: 33))
        p.closeSubpath()
        return p
    }()

    /// Four broad sepals seen at three-quarters: two reach out along the shoulders, two fold down
    /// toward the viewer. Chunky on purpose so the rosette survives at 29 pt.
    static let calyx: CGPath = {
        let parts = [
            sepal(from: crown, to: CGPoint(x: 21, y: 38.5), width: 6.6, bend: -1.6),   // left
            sepal(from: crown, to: CGPoint(x: 79, y: 38.5), width: 6.6, bend: 1.6),    // right
            sepal(from: crown, to: CGPoint(x: 36, y: 51), width: 6.0, bend: 1.0),      // front left
            sepal(from: crown, to: CGPoint(x: 64, y: 51), width: 6.0, bend: -1.0),     // front right
            CGPath(ellipseIn: CGRect(x: crown.x - 7.5, y: crown.y - 5.5, width: 15, height: 10), transform: nil),
        ]
        return parts.dropFirst().reduce(parts[0]) { $0.union($1) }
    }()

    /// A short woody stem, curling a little to the right.
    static let stem: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 49.5, y: 35))
        p.addCurve(to: CGPoint(x: 54.5, y: 21.5), control1: CGPoint(x: 49.5, y: 29), control2: CGPoint(x: 51, y: 24))
        let stroked = p.copy(strokingWithWidth: 6.4, lineCap: .round, lineJoin: .round, miterLimit: 4)
        return stroked
    }()

    /// Calyx and stem as one shape.
    static let crownShape: CGPath = calyx.union(stem)

    /// The fruit with a hairline gap cut around the calyx, so the two read apart in one colour.
    static func fruitKnockedOut(gap: CGFloat) -> CGPath {
        let halo = crownShape.copy(strokingWithWidth: gap * 2, lineCap: .round, lineJoin: .round, miterLimit: 4)
        return fruit.subtracting(halo.union(crownShape))
    }

    /// A soft crescent of light on the upper-left of the fruit.
    static let highlight: CGPath = {
        let outer = CGPath(ellipseIn: CGRect(x: 17, y: 49, width: 22, height: 30), transform: nil)
        let inner = CGPath(ellipseIn: CGRect(x: 22, y: 46.5, width: 24, height: 33), transform: nil)
        return outer.subtracting(inner).intersection(fruit)
    }()
}

// MARK: - Wordmark (Bagel Fat One → paths)

func registerFont() -> CTFont {
    var error: Unmanaged<CFError>?
    if !CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error) {
        // Already registered in this process is fine.
    }
    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fontURL as CFURL) as? [CTFontDescriptor],
          let descriptor = descriptors.first
    else { fatalError("Bagel Fat One not found at \(fontURL.path)") }
    return CTFontCreateWithFontDescriptor(descriptor, 100, nil)
}

let bagel = registerFont()

/// Outlines `text` at `size` (y down, baseline at y = 0, origin at the left edge of the ink) and
/// returns the path plus its advance-box metrics.
func outline(_ text: String, size: CGFloat, tracking: CGFloat = 0) -> (path: CGPath, ascent: CGFloat, descent: CGFloat) {
    let font = CTFontCreateCopyWithAttributes(bagel, size, nil, nil)
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTKernAttributeName as String): tracking,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let path = CGMutablePath()
    for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        for (glyph, position) in zip(glyphs, positions) {
            var transform = CGAffineTransform(translationX: position.x, y: 0).scaledBy(x: 1, y: -1)
            if let glyphPath = CTFontCreatePathForGlyph(runFont, glyph, &transform) { path.addPath(glyphPath) }
        }
    }
    let bounds = path.boundingBoxOfPath
    var shift = CGAffineTransform(translationX: -bounds.minX, y: 0)
    let shifted = path.copy(using: &shift) ?? path
    return (shifted, CTFontGetAscent(font), CTFontGetDescent(font))
}

// MARK: - SVG writing

func svgData(_ path: CGPath) -> String {
    var d = ""
    func f(_ v: CGFloat) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }
    path.applyWithBlock { element in
        let e = element.pointee
        let p = e.points
        switch e.type {
        case .moveToPoint: d += "M\(f(p[0].x)) \(f(p[0].y))"
        case .addLineToPoint: d += "L\(f(p[0].x)) \(f(p[0].y))"
        case .addQuadCurveToPoint: d += "Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))"
        case .addCurveToPoint:
            d += "C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

struct Layer {
    let path: CGPath
    let fill: String
}

func transformed(_ path: CGPath, _ t: CGAffineTransform) -> CGPath {
    var t = t
    return path.copy(using: &t) ?? path
}

func writeSVG(_ name: String, to dir: URL, width: CGFloat, height: CGFloat, title: String,
              layers: [Layer], background: String? = nil, pointSize: (CGFloat, CGFloat)? = nil) throws {
    let w = pointSize?.0 ?? width, h = pointSize?.1 ?? height
    var body = ""
    if let background { body += "  <rect width=\"\(Int(width))\" height=\"\(Int(height))\" fill=\"\(background)\"/>\n" }
    for layer in layers {
        body += "  <path fill=\"\(layer.fill)\" fill-rule=\"evenodd\" d=\"\(svgData(layer.path))\"/>\n"
    }
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(Int(width)) \(Int(height))" width="\(Int(w))" height="\(Int(h))" role="img" aria-label="\(title)">
      <title>\(title)</title>
    \(body)</svg>

    """
    try svg.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

// MARK: - Mark variants

struct MarkColors {
    let fruit: String
    let crown: String
    let highlight: String?
}

let gap: CGFloat = 1.6
let fruitCut = Mark.fruitKnockedOut(gap: gap)

func markLayers(_ colors: MarkColors, _ t: CGAffineTransform = .identity) -> [Layer] {
    var layers = [Layer(path: transformed(fruitCut, t), fill: colors.fruit)]
    if let highlight = colors.highlight {
        layers.append(Layer(path: transformed(Mark.highlight, t), fill: highlight))
    }
    layers.append(Layer(path: transformed(Mark.crownShape, t), fill: colors.crown))
    return layers
}

let onLight = MarkColors(fruit: hex(Brand.persimmon), crown: hex(Brand.leaf), highlight: hex(Brand.persimmonLight))
let onDark = MarkColors(fruit: hex(Brand.persimmonDark), crown: hex(Brand.leafDark), highlight: "#FFAE73")

/// The mark's ink sits in x 9…91, y 19…90; this crops it to a square with a little air.
let markBox = CGRect(x: 4, y: 9, width: 92, height: 92)
let toMarkBox = CGAffineTransform(translationX: -markBox.minX, y: -markBox.minY)

try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)

try writeSVG("umma-mark.svg", to: brandDir, width: markBox.width, height: markBox.height,
             title: "Umma persimmon mark", layers: markLayers(onLight, toMarkBox), pointSize: (512, 512))
try writeSVG("umma-mark-dark.svg", to: brandDir, width: markBox.width, height: markBox.height,
             title: "Umma persimmon mark, for dark backgrounds", layers: markLayers(onDark, toMarkBox), pointSize: (512, 512))
try writeSVG("umma-mark-mono.svg", to: brandDir, width: markBox.width, height: markBox.height,
             title: "Umma persimmon mark, one colour",
             layers: markLayers(MarkColors(fruit: "currentColor", crown: "currentColor", highlight: nil), toMarkBox),
             pointSize: (512, 512))
// Favicon: the mark alone, no highlight (it muddies at 16 px).
try writeSVG("favicon.svg", to: brandDir, width: markBox.width, height: markBox.height, title: "Umma",
             layers: markLayers(MarkColors(fruit: hex(Brand.persimmon), crown: hex(Brand.leaf), highlight: nil), toMarkBox),
             pointSize: (32, 32))

// MARK: - Wordmark and lockups

let wordSize: CGFloat = 100
let word = outline("umma", size: wordSize, tracking: 1)
let wordBounds = word.path.boundingBoxOfPath   // y is negative above the baseline
let hangul = outline("엄마", size: 46, tracking: 0.5)
let hangulBounds = hangul.path.boundingBoxOfPath

func wordmark(at origin: CGPoint) -> CGPath {
    transformed(word.path, CGAffineTransform(translationX: origin.x, y: origin.y - wordBounds.minY))
}

// Wordmark alone, cropped to its ink plus a 6-unit margin.
do {
    let pad: CGFloat = 6
    let path = wordmark(at: CGPoint(x: pad, y: pad))
    try writeSVG("umma-wordmark.svg", to: brandDir, width: (wordBounds.width + pad * 2).rounded(.up),
                 height: (wordBounds.height + pad * 2).rounded(.up), title: "umma",
                 layers: [Layer(path: path, fill: hex(Brand.leaf))])
    try writeSVG("umma-wordmark-dark.svg", to: brandDir, width: (wordBounds.width + pad * 2).rounded(.up),
                 height: (wordBounds.height + pad * 2).rounded(.up), title: "umma",
                 layers: [Layer(path: path, fill: hex(Brand.leafDark))])
}

/// Mark scaled so its height matches the wordmark's x-height-plus-ascender, sitting left of it.
func lockup(korean: Bool, dark: Bool) -> (layers: [Layer], width: CGFloat, height: CGFloat) {
    let pad: CGFloat = 10
    let markHeight = wordBounds.height * (korean ? 1.75 : 1.32)
    let scale = markHeight / markBox.height
    let markT = toMarkBox.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        .concatenating(CGAffineTransform(translationX: pad, y: pad))
    let textX = pad + markBox.width * scale + wordBounds.height * 0.22
    let stackHeight = korean ? wordBounds.height + hangulBounds.height + wordBounds.height * 0.22 : wordBounds.height
    let textY = pad + (markHeight - stackHeight) / 2 + (korean ? 0 : markHeight * 0.06)
    var layers = markLayers(dark ? onDark : onLight, markT)
    layers.append(Layer(path: wordmark(at: CGPoint(x: textX, y: textY)), fill: hex(dark ? Brand.leafDark : Brand.leaf)))
    var width = textX + wordBounds.width + pad
    if korean {
        let y = textY + wordBounds.height + wordBounds.height * 0.22 - hangulBounds.minY
        let k = transformed(hangul.path, CGAffineTransform(translationX: textX + 3, y: y))
        layers.append(Layer(path: k, fill: hex(dark ? Brand.persimmonDark : Brand.persimmonDeep)))
        width = max(width, textX + 3 + hangulBounds.width + pad)
    }
    return (layers, width.rounded(.up), (markHeight + pad * 2).rounded(.up))
}

for (korean, dark, name, title) in [
    (false, false, "umma-lockup-horizontal.svg", "Umma"),
    (false, true, "umma-lockup-horizontal-dark.svg", "Umma"),
    (true, false, "umma-lockup-korean.svg", "Umma 엄마"),
    (true, true, "umma-lockup-korean-dark.svg", "Umma 엄마"),
] {
    let l = lockup(korean: korean, dark: dark)
    try writeSVG(name, to: brandDir, width: l.width, height: l.height, title: title, layers: l.layers)
}

// In-app vector asset: the colour mark at 96 pt (launch screen and sign-in header).
do {
    let set = assets.appendingPathComponent("BrandMark.imageset")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    try writeSVG("BrandMark.svg", to: set, width: markBox.width, height: markBox.height, title: "Umma",
                 layers: markLayers(onLight, toMarkBox), pointSize: (96, 96))
    try writeSVG("BrandMark-dark.svg", to: set, width: markBox.width, height: markBox.height, title: "Umma",
                 layers: markLayers(onDark, toMarkBox), pointSize: (96, 96))
    let contents = """
    {
      "images" : [
        { "filename" : "BrandMark.svg", "idiom" : "universal" },
        {
          "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
          "filename" : "BrandMark-dark.svg",
          "idiom" : "universal"
        }
      ],
      "info" : { "author" : "xcode", "version" : 1 },
      "properties" : { "preserves-vector-representation" : true }
    }

    """
    try contents.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

// MARK: - App icons (1024 px)

struct IconVariant {
    let file: String
    let tile: (top: UInt32, bottom: UInt32)?
    let fruit: CGColor
    let crown: CGColor
    let highlight: CGColor?
}

let icons = [
    // Light (PM decision, 2026-11-12): the colour mark itself — Persimmon fruit, Leaf calyx — on a
    // pale Flesh tile, so the home-screen icon reads literally as a persimmon.
    IconVariant(file: "AppIcon-light.png", tile: (0xFFF7F0, 0xFFE4CF), fruit: cg(Brand.persimmon), crown: cg(Brand.leaf),
                highlight: cg(Brand.persimmonLight)),
    // Dark: transparent so iOS draws its dark backdrop; the fruit itself carries the colour.
    IconVariant(file: "AppIcon-dark.png", tile: nil, fruit: cg(Brand.persimmonDark), crown: cg(Brand.leafDark),
                highlight: cg(0xFFAE73)),
    // Tinted: grayscale on transparent. iOS maps luminance to the tint, so the fruit is near white
    // and the calyx a mid grey; the knockout gap keeps them apart.
    IconVariant(file: "AppIcon-tinted.png", tile: nil, fruit: cg(0xF2F2F2), crown: cg(0x8C8C8C), highlight: nil),
]

func renderIcon(_ variant: IconVariant, size: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size)
    context.translateBy(x: 0, y: s)
    context.scaleBy(x: 1, y: -1)
    if let tile = variant.tile {
        let gradient = CGGradient(colorsSpace: space, colors: [cg(tile.top), cg(tile.bottom)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: s * 0.2, y: 0), end: CGPoint(x: s * 0.8, y: s),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    // The mark's ink (x 9…91, y 19…90) fills ~74% of the tile, optically centred.
    let scale = s * 0.0090
    context.translateBy(x: s / 2 - 50 * scale, y: s / 2 - 55 * scale)
    context.scaleBy(x: scale, y: scale)
    context.setFillColor(variant.fruit)
    context.addPath(fruitCut)
    context.fillPath(using: .evenOdd)
    if let highlight = variant.highlight {
        context.setFillColor(highlight)
        context.addPath(Mark.highlight)
        context.fillPath(using: .evenOdd)
    }
    context.setFillColor(variant.crown)
    context.addPath(Mark.crownShape)
    context.fillPath(using: .evenOdd)
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "png", code: 1) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "png", code: 2) }
}

let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
for variant in icons {
    try writePNG(renderIcon(variant, size: 1024), to: iconSet.appendingPathComponent(variant.file))
}

// MARK: - Previews: the icons as the home screen shows them, plus the 29 pt Settings size.

func homeScreenPreview() throws {
    let cell = 340, sizes: [CGFloat] = [180, 87, 58]   // 60 pt @3x, 29 pt @3x, 29 pt @2x
    let width = cell * icons.count, height = 420
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let backdrops: [UInt32] = [0xDDE3EA, 0x1C1C1E, 0x2B3240]
    for (index, variant) in icons.enumerated() {
        let x = CGFloat(index * cell)
        context.setFillColor(cg(backdrops[index]))
        context.fill(CGRect(x: x, y: 0, width: CGFloat(cell), height: CGFloat(height)))
        var cursorY: CGFloat = CGFloat(height) - 24
        for size in sizes {
            cursorY -= size
            let rect = CGRect(x: x + (CGFloat(cell) - size) / 2, y: cursorY, width: size, height: size)
            let mask = CGPath(roundedRect: rect, cornerWidth: size * 0.225, cornerHeight: size * 0.225, transform: nil)
            context.saveGState()
            context.addPath(mask)
            context.clip()
            if variant.tile == nil {
                // What iOS draws behind a transparent dark / tinted icon.
                let tint: (UInt32, UInt32) = index == 1 ? (0x3A3A3C, 0x1C1C1E) : (0x4A5568, 0x2D3748)
                let g = CGGradient(colorsSpace: space, colors: [cg(tint.0), cg(tint.1)] as CFArray, locations: [0, 1])!
                context.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
            }
            var image = renderIcon(variant, size: 1024)
            if index == 2 {
                // Simulate the tint: multiply the grayscale by a cool blue.
                image = tinted(image, with: cg(0x8FB8FF)) ?? image
            }
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            context.restoreGState()
            cursorY -= 16
        }
    }
    try writePNG(context.makeImage()!, to: previewDir.appendingPathComponent("app-icon-variants.png"))
}

func tinted(_ image: CGImage, with color: CGColor) -> CGImage? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    context.draw(image, in: rect)
    context.setBlendMode(.multiply)
    context.setFillColor(color)
    context.clip(to: rect, mask: image)
    context.fill(rect)
    return context.makeImage()
}

try homeScreenPreview()
print("Wrote brand masters to \(brandDir.path), icons to \(iconSet.path)")
