#!/usr/bin/env swift
// Renders the SousLens "leaf-lens" app icon (brief 006, DECISIONS #17: eng draws it in code).
// A herb-green leaf whose upper edge is notched by a camera lens. The geometry below is the
// source of truth; the PNGs in AppIcon.appiconset are generated from it.
//
//   swift ios/scripts/render-app-icon.swift ios/SousLens/Resources/Assets.xcassets/AppIcon.appiconset
//
// Writes AppIcon-light.png (cream tile), AppIcon-dark.png (transparent, light-green leaf) and
// AppIcon-tinted.png (transparent, white leaf; iOS applies the tint), each 1024×1024.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let outDir = CommandLine.arguments.dropFirst().first ?? "."

struct Variant {
    let file: String
    let background: CGColor?
    let leaf: CGColor
}

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let variants = [
    Variant(file: "AppIcon-light.png", background: rgb(0xFBF6EE), leaf: rgb(0x2F6B3A)),
    Variant(file: "AppIcon-dark.png", background: nil, leaf: rgb(0x7FCB8C)),
    Variant(file: "AppIcon-tinted.png", background: nil, leaf: rgb(0xFFFFFF)),
]

// Geometry, in a 1024 canvas with y pointing down (flipped below).
let tip = CGPoint(x: 268, y: 756)          // stem end of the leaf (bottom-left)
let apex = CGPoint(x: 768, y: 256)         // leaf point (top-right)
let upperControl = CGPoint(x: 214, y: 214) // upper-left edge bulge
let lowerControl = CGPoint(x: 810, y: 810) // lower-right edge bulge
let lensCenter = CGPoint(x: 398, y: 398)   // sits on the upper edge: the notch
let notchRadius: CGFloat = 132
let pupilRadius: CGFloat = 72
let glint = (center: CGPoint(x: 374, y: 374), radius: CGFloat(20))

func leafPath() -> CGPath {
    let path = CGMutablePath()
    path.move(to: tip)
    path.addQuadCurve(to: apex, control: upperControl)
    path.addQuadCurve(to: tip, control: lowerControl)
    path.closeSubpath()
    return path
}

func render(_ variant: Variant) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw NSError(domain: "icon", code: 1) }
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: 1, y: -1)

    if let background = variant.background {
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }

    // Leaf body + stem.
    context.setFillColor(variant.leaf)
    context.addPath(leafPath())
    context.fillPath()
    context.setStrokeColor(variant.leaf)
    context.setLineCap(.round)
    context.setLineWidth(46)
    context.move(to: CGPoint(x: tip.x + 20, y: tip.y - 20))
    context.addLine(to: CGPoint(x: 196, y: 828))
    context.strokePath()

    // Cut-outs: the lens notch and the midrib are knocked out of the leaf (clear on the
    // transparent variants, cream on the light tile).
    context.saveGState()
    context.setBlendMode(.clear)
    context.addEllipse(in: CGRect(x: lensCenter.x - notchRadius, y: lensCenter.y - notchRadius,
                                  width: notchRadius * 2, height: notchRadius * 2))
    context.fillPath()
    context.setLineWidth(18)
    context.move(to: CGPoint(x: 318, y: 706))
    context.addLine(to: CGPoint(x: 694, y: 330))
    context.strokePath()
    context.restoreGState()
    if let background = variant.background {
        // Re-fill the knocked-out areas with the tile colour so the light icon stays opaque.
        context.saveGState()
        context.setBlendMode(.destinationOver)
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.restoreGState()
    }

    // Lens pupil in the notch, with a glint.
    context.setFillColor(variant.leaf)
    context.addEllipse(in: CGRect(x: lensCenter.x - pupilRadius, y: lensCenter.y - pupilRadius,
                                  width: pupilRadius * 2, height: pupilRadius * 2))
    context.fillPath()
    context.saveGState()
    if variant.background == nil { context.setBlendMode(.clear) } else { context.setFillColor(variant.background!) }
    context.addEllipse(in: CGRect(x: glint.center.x - glint.radius, y: glint.center.y - glint.radius,
                                  width: glint.radius * 2, height: glint.radius * 2))
    context.fillPath()
    context.restoreGState()

    guard let image = context.makeImage() else { throw NSError(domain: "icon", code: 2) }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(variant.file)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "icon", code: 3) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "icon", code: 4) }
    print("wrote \(url.path)")
}

for variant in variants {
    try render(variant)
}
