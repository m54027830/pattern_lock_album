#!/usr/bin/env swift
import CoreGraphics
import CoreText
import Foundation
import ImageIO

// Standalone concept artwork. Run with: swift output/icon-concepts-2026-11-12/generate.swift
// This intentionally writes only into this proposal folder.
let destination = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 255) / 255,
        CGFloat((hex >> 8) & 255) / 255,
        CGFloat(hex & 255) / 255, 1
    ])!
}

func context(_ width: Int, _ height: Int) -> CGContext {
    let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: width * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.translateBy(x: 0, y: CGFloat(height))
    c.scaleBy(x: 1, y: -1)
    return c
}

func rect(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat,
          _ h: CGFloat, _ radius: CGFloat, _ hex: UInt32) {
    c.setFillColor(color(hex))
    c.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h),
                     cornerWidth: radius, cornerHeight: radius, transform: nil))
    c.fillPath()
}

func render(_ index: Int, pixels: Int = 1024) -> CGImage {
    let c = context(pixels, pixels)
    c.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    switch index {
    case 0:
        rect(c, 0, 0, 1024, 1024, 0, 0xE6E9E9)
        c.setFillColor(color(0x65777C))
        for y in [336, 512, 688] {
            for x in [336, 512, 688] {
                c.fillEllipse(in: CGRect(x: x - 42, y: y - 42, width: 84, height: 84))
            }
        }
    case 1:
        rect(c, 0, 0, 1024, 1024, 0, 0x6C7F86)
        rect(c, 280, 280, 360, 360, 58, 0x94A1A5)
        rect(c, 384, 384, 360, 360, 58, 0xCCD2D1)
    default:
        rect(c, 0, 0, 1024, 1024, 0, 0x3F484A)
        c.setStrokeColor(color(0xADB9B7))
        c.setLineWidth(64)
        c.setLineCap(.round)
        c.setLineJoin(.round)
        c.move(to: CGPoint(x: 592, y: 320))
        c.addLine(to: CGPoint(x: 384, y: 320))
        c.addQuadCurve(to: CGPoint(x: 320, y: 384), control: CGPoint(x: 320, y: 320))
        c.addLine(to: CGPoint(x: 320, y: 592))
        c.move(to: CGPoint(x: 432, y: 704))
        c.addLine(to: CGPoint(x: 640, y: 704))
        c.addQuadCurve(to: CGPoint(x: 704, y: 640), control: CGPoint(x: 704, y: 704))
        c.addLine(to: CGPoint(x: 704, y: 432))
        c.strokePath()
    }
    return c.makeImage()!
}

func save(_ image: CGImage, _ filename: String) {
    let url = destination.appendingPathComponent(filename)
    let writer = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(writer, image, nil)
    precondition(CGImageDestinationFinalize(writer), "Could not write \(filename)")
}

func text(_ c: CGContext, _ value: String, _ x: CGFloat, _ y: CGFloat,
          _ size: CGFloat, _ hex: UInt32, bold: Bool = false) {
    let font = CTFontCreateWithName((bold ? "HelveticaNeue-Medium" : "HelveticaNeue") as CFString, size, nil)
    let attributed = NSAttributedString(string: value, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(hex)
    ])
    c.saveGState()
    c.translateBy(x: x, y: y + CTFontGetAscent(font))
    c.scaleBy(x: 1, y: -1)
    c.textMatrix = .identity
    c.textPosition = .zero
    CTLineDraw(CTLineCreateWithAttributedString(attributed), c)
    c.restoreGState()
}

func icon(_ c: CGContext, _ image: CGImage, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
    c.saveGState()
    c.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: size, height: size),
                     cornerWidth: size * 0.224, cornerHeight: size * 0.224, transform: nil))
    c.clip()
    c.interpolationQuality = .high
    c.translateBy(x: x, y: y + size)
    c.scaleBy(x: 1, y: -1)
    c.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    c.restoreGState()
}

let names = ["01-quiet-grid", "02-layers", "03-open-frame"]
let titles = ["Quiet grid", "Layers", "Open frame"]
let descriptions = [
    ["A familiar rhythm of nine dots.", "Soft silver with a muted slate mark."],
    ["Two overlapping, rounded tiles.", "A subtle nod to an album."],
    ["Two corners, with room between.", "A simple mark in warm graphite."]
]
let images = (0..<3).map { render($0) }
for (i, image) in images.enumerated() {
    save(image, "\(names[i]).png")
}

let dotSVG = [336, 512, 688].flatMap { y in
    [336, 512, 688].map { x in "<circle cx=\"\(x)\" cy=\"\(y)\" r=\"42\"/>" }
}.joined(separator: "\n    ")
let drawings = [
    "<rect width=\"1024\" height=\"1024\" fill=\"#E6E9E9\"/>\n  <g fill=\"#65777C\">\n    \(dotSVG)\n  </g>",
    "<rect width=\"1024\" height=\"1024\" fill=\"#6C7F86\"/>\n  <rect x=\"280\" y=\"280\" width=\"360\" height=\"360\" rx=\"58\" fill=\"#94A1A5\"/>\n  <rect x=\"384\" y=\"384\" width=\"360\" height=\"360\" rx=\"58\" fill=\"#CCD2D1\"/>",
    "<rect width=\"1024\" height=\"1024\" fill=\"#3F484A\"/>\n  <path d=\"M592 320H384Q320 320 320 384V592 M432 704H640Q704 704 704 640V432\" fill=\"none\" stroke=\"#ADB9B7\" stroke-width=\"64\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
]
for i in 0..<3 {
    let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-label="Pattern icon concept: \(titles[i])">
      \(drawings[i])
    </svg>
    """
    try svg.write(to: destination.appendingPathComponent("\(names[i]).svg"), atomically: true, encoding: .utf8)
}

// Comparison sheet: the same artwork at large and Home Screen preview sizes.
let board = context(1600, 1050)
rect(board, 0, 0, 1600, 1050, 0, 0xF7F7F4)
text(board, "PATTERN  /  ICON STUDIES", 96, 60, 17, 0x65716E, bold: true)
text(board, "A quieter presence.", 94, 106, 48, 0x26312F, bold: true)
text(board, "Three simple marks. Muted color. Plenty of space.", 96, 173, 22, 0x747D79)

for i in 0..<3 {
    let left = CGFloat(96 + i * 494)
    if i > 0 { rect(board, left - 48, 270, 1, 654, 0, 0xDDDFD9) }
    icon(board, images[i], left + 58, 266, 280)
    text(board, "0\(i + 1)", left, 599, 18, 0x7B8580, bold: true)
    text(board, titles[i], left + 40, 591, 31, 0x26312F, bold: true)
    for (line, value) in descriptions[i].enumerated() {
        text(board, value, left, CGFloat(647 + line * 31), 21, 0x69736E)
    }
    rect(board, left, 751, 185, 144, 20, 0xECEEE8)
    rect(board, left + 203, 751, 185, 144, 20, 0x242B2D)
    icon(board, render(i, pixels: 180), left + 62, 774, 60)
    icon(board, render(i, pixels: 180), left + 265, 774, 60)
    text(board, "Pattern", left + 62, 845, 16, 0x59635E)
    text(board, "Pattern", left + 265, 845, 16, 0xD2D9D6)
}
text(board, "SMALL-SIZE PREVIEWS ON LIGHT AND DARK BACKGROUNDS", 96, 951, 15, 0x818A83, bold: true)
save(board.makeImage()!, "comparison.png")
print("Saved three 1024 × 1024 PNGs, editable SVGs, and comparison.png to \(destination.path)")
