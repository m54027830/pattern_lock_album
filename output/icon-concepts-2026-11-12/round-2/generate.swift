#!/usr/bin/env swift
import CoreGraphics
import CoreText
import Foundation
import ImageIO

// Run with: swift output/icon-concepts-2026-11-12/round-2/generate.swift
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

let pDots = ["1110", "1001", "1110", "1000", "1000"]

func render(_ index: Int, pixels: Int = 1024) -> CGImage {
    let c = context(pixels, pixels)
    c.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    switch index {
    case 0:
        rect(c, 0, 0, 1024, 1024, 0, 0xE6E9E9)
        c.setStrokeColor(color(0x65777C))
        c.setLineWidth(30)
        c.setLineJoin(.round)
        c.setLineCap(.round)
        c.addLines(between: [CGPoint(x: 336, y: 688), CGPoint(x: 336, y: 336),
                            CGPoint(x: 688, y: 336), CGPoint(x: 688, y: 512),
                            CGPoint(x: 336, y: 512)])
        c.strokePath()
        for y in [336, 512, 688] {
            for x in [336, 512, 688] {
                c.setFillColor(color(y == 688 && x > 336 ? 0xBBC6C7 : 0x65777C))
                c.fillEllipse(in: CGRect(x: x - 36, y: y - 36, width: 72, height: 72))
            }
        }
    case 1:
        rect(c, 0, 0, 1024, 1024, 0, 0xE6E9E9)
        for (row, pattern) in pDots.enumerated() {
            for (column, active) in pattern.enumerated() {
                let x = 362 + column * 100
                let y = 312 + row * 100
                c.setFillColor(color(active == "1" ? 0x65777C : 0xD3DADB))
                c.fillEllipse(in: CGRect(x: x - 28, y: y - 28, width: 56, height: 56))
            }
        }
    default:
        let gradient = CGGradient(colorsSpace: space,
                                  colors: [color(0x92A3A2), color(0x738B91), color(0x526A77)] as CFArray,
                                  locations: [0, 0.5, 1])!
        c.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0),
                             end: CGPoint(x: 1024, y: 1024),
                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.saveGState()
        c.setAlpha(0.14)
        c.setFillColor(color(0xD0D8CF))
        c.move(to: CGPoint(x: 0, y: 0))
        c.addLine(to: CGPoint(x: 1024, y: 0))
        c.addCurve(to: CGPoint(x: 0, y: 700), control1: CGPoint(x: 760, y: 270),
                   control2: CGPoint(x: 180, y: 210))
        c.closePath()
        c.fillPath()
        c.setAlpha(0.12)
        c.setFillColor(color(0x334F62))
        c.move(to: CGPoint(x: 0, y: 1024))
        c.addLine(to: CGPoint(x: 1024, y: 1024))
        c.addLine(to: CGPoint(x: 1024, y: 440))
        c.addCurve(to: CGPoint(x: 0, y: 1024), control1: CGPoint(x: 750, y: 810),
                   control2: CGPoint(x: 360, y: 610))
        c.closePath()
        c.fillPath()
        c.restoreGState()
        rect(c, 280, 280, 360, 360, 58, 0xA6B4B5)
        rect(c, 384, 384, 360, 360, 58, 0xDBE0DB)
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

let names = ["01-linked-p", "02-dotted-p", "03-layers-atmosphere"]
let titles = ["Linked P", "Dotted P", "Layers / Atmosphere"]
let descriptions = [
    ["The nine dots trace a quiet P.", "Closest to the original grid."],
    ["A P emerges from a field of dots.", "A more abstract monogram."],
    ["Soft blue-grey with tonal curves.", "A little depth behind simple tiles."]
]
let images = (0..<3).map { render($0) }
for (i, image) in images.enumerated() {
    save(image, "\(names[i]).png")
}

let dotSVG = [336, 512, 688].flatMap { y in
    [336, 512, 688].map { x in
        let fill = y == 688 && x > 336 ? "#BBC6C7" : "#65777C"
        return "<circle cx=\"\(x)\" cy=\"\(y)\" r=\"36\" fill=\"\(fill)\"/>"
    }
}.joined(separator: "\n    ")
let pDotSVG = pDots.enumerated().flatMap { row, pattern in
    pattern.enumerated().map { column, active in
        let fill = active == "1" ? "#65777C" : "#D3DADB"
        return "<circle cx=\"\(362 + column * 100)\" cy=\"\(312 + row * 100)\" r=\"28\" fill=\"\(fill)\"/>"
    }
}.joined(separator: "\n    ")
let drawings = [
    """
    <rect width="1024" height="1024" fill="#E6E9E9"/>
      <path d="M336 688V336H688V512H336" fill="none" stroke="#65777C" stroke-width="30" stroke-linecap="round" stroke-linejoin="round"/>
      \(dotSVG)
    """,
    """
    <rect width="1024" height="1024" fill="#E6E9E9"/>
      \(pDotSVG)
    """,
    """
    <defs>
        <linearGradient id="sky" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stop-color="#92A3A2"/>
          <stop offset=".5" stop-color="#738B91"/>
          <stop offset="1" stop-color="#526A77"/>
        </linearGradient>
      </defs>
      <rect width="1024" height="1024" fill="url(#sky)"/>
      <path d="M0 0H1024C760 270 180 210 0 700Z" fill="#D0D8CF" opacity=".14"/>
      <path d="M0 1024H1024V440C750 810 360 610 0 1024Z" fill="#334F62" opacity=".12"/>
      <rect x="280" y="280" width="360" height="360" rx="58" fill="#A6B4B5"/>
      <rect x="384" y="384" width="360" height="360" rx="58" fill="#DBE0DB"/>
    """
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
text(board, "PATTERN  /  ICON STUDIES 02", 96, 60, 17, 0x65716E, bold: true)
text(board, "A little more character.", 94, 106, 48, 0x26312F, bold: true)
text(board, "Two ways to work in a P. One softer, richer backdrop.", 96, 173, 22, 0x747D79)

for i in 0..<3 {
    let left = CGFloat(96 + i * 494)
    if i > 0 { rect(board, left - 48, 270, 1, 654, 0, 0xDDDFD9) }
    icon(board, images[i], left + 58, 266, 280)
    text(board, "0\(i + 1)", left, 599, 18, 0x7B8580, bold: true)
    text(board, titles[i], left + 40, 591, i == 2 ? 28 : 31, 0x26312F, bold: true)
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
