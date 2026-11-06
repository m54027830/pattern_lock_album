#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO

// Original abstract geometry for the alternate Pattern app icons.
// App icons and picker previews use the same drawing at different resolutions.
let names = ["Classic", "Square", "Triangles", "Checker", "Stripes", "Rings", "Diamonds", "Waves", "Hexagons", "Mosaic"]
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    let rgb = [CGFloat((hex >> 16) & 255), CGFloat((hex >> 8) & 255), CGFloat(hex & 255)].map { $0 / 255 }
    return CGColor(colorSpace: space, components: rgb + [alpha])!
}
func render(_ name: String, pixels: Int) -> CGImage {
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                      bytesPerRow: pixels * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    c.translateBy(x: 0, y: 1024)
    c.scaleBy(x: 1, y: -1)
    func fill(_ hex: UInt32) { c.setFillColor(color(hex)) }
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ hex: UInt32) {
        fill(hex)
        c.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil))
        c.fillPath()
    }
    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ hex: UInt32) {
        fill(hex); c.fillEllipse(in: CGRect(x: x-r, y: y-r, width: r*2, height: r*2))
    }
    func line(_ points: [CGPoint], _ width: CGFloat, _ hex: UInt32) {
        c.setStrokeColor(color(hex)); c.setLineWidth(width); c.setLineCap(.round); c.setLineJoin(.round)
        c.beginPath(); c.addLines(between: points); c.strokePath()
    }
    func polygon(_ points: [CGPoint], _ hex: UInt32) {
        fill(hex); c.beginPath(); c.addLines(between: points); c.closePath(); c.fillPath()
    }
    func background(_ top: UInt32, _ bottom: UInt32? = nil) {
        rect(0, 0, 1024, 1024, 0, top)
        if let bottom {
            let gradient = CGGradient(colorsSpace: space, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
            c.drawLinearGradient(gradient, start: CGPoint(x: 100, y: 0), end: CGPoint(x: 900, y: 1024), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }
    switch name {
    case "Classic":
        let bg: [CGFloat] = [0.965, 0.961, 0.945], accent: [CGFloat] = [0.22, 0.38, 0.32]
        c.setFillColor(CGColor(colorSpace: space, components: bg + [1])!); c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        for row in 0..<3 { for col in 0..<3 {
            let opacity: CGFloat = row == col || col == 2 ? 1 : 0.23
            let rgb = zip(accent, bg).map { $0 * opacity + $1 * (1-opacity) }
            c.setFillColor(CGColor(colorSpace: space, components: rgb + [1])!)
            c.fillEllipse(in: CGRect(x: 192 + CGFloat(col)*256, y: 192 + CGFloat(row)*256, width: 128, height: 128))
        } }
    case "Square":
        background(0xEEEDE4)
        rect(232, 232, 560, 560, 0, 0x345C4D)
    case "Triangles":
        background(0x275485)
        let palette: [UInt32] = [0x17375D, 0x386C9B, 0x80A7C5, 0xD2E1E9, 0x547FA8]
        let side: CGFloat = 1024 / 3
        for row in 0..<3 { for col in 0..<3 {
            let x = CGFloat(col)*side, y = CGFloat(row)*side
            let a = CGPoint(x: x, y: y), b = CGPoint(x: x+side, y: y)
            let d = CGPoint(x: x, y: y+side), e = CGPoint(x: x+side, y: y+side)
            let index = row*3+col
            if (row+col) % 2 == 0 {
                polygon([a,b,e], palette[index % palette.count])
                polygon([a,e,d], palette[(index+2) % palette.count])
            } else {
                polygon([a,b,d], palette[index % palette.count])
                polygon([b,e,d], palette[(index+3) % palette.count])
            }
        } }
    case "Checker":
        background(0xEFE1C5)
        for row in 0..<4 { for col in 0..<4 where (row+col) % 2 == 0 {
            rect(CGFloat(col)*256, CGFloat(row)*256, 256, 256, 0, 0xAB674C)
        } }
    case "Stripes":
        background(0xF0D49C)
        for offset in stride(from: -1024, through: 2048, by: 256) {
            let x = CGFloat(offset)
            polygon([CGPoint(x: x, y: 0), CGPoint(x: x+128, y: 0), CGPoint(x: x-896, y: 1024), CGPoint(x: x-1024, y: 1024)], 0xC16D48)
        }
    case "Rings":
        background(0x263E40)
        for (index, radius) in [CGFloat(760), 620, 480, 340, 200, 60].enumerated() {
            circle(512, 512, radius, index % 2 == 0 ? 0x263E40 : 0xDEE7D8)
        }
    case "Diamonds":
        background(0xE4D9EE)
        let palette: [UInt32] = [0x65567F, 0xA08BB6, 0xC5B2D2]
        for row in -1...5 { for col in -1...5 {
            let x = CGFloat(col)*256 + (row % 2 == 0 ? 0 : 128)
            let y = CGFloat(row)*256
            polygon([CGPoint(x: x, y: y-128), CGPoint(x: x+128, y: y), CGPoint(x: x, y: y+128), CGPoint(x: x-128, y: y)], palette[((row+col)%3+3)%3])
        } }
    case "Waves":
        background(0xD4E6DE)
        let palette: [UInt32] = [0xA6C8BC, 0x70A699, 0x3A7C77, 0x23575B]
        for i in 0..<4 {
            let y = 180 + CGFloat(i)*205
            fill(palette[i]); c.move(to: CGPoint(x: 0, y: y))
            c.addCurve(to: CGPoint(x: 1024, y: y-90), control1: CGPoint(x: 280, y: y-240), control2: CGPoint(x: 720, y: y+200))
            c.addLine(to: CGPoint(x: 1024, y: 1024)); c.addLine(to: CGPoint(x: 0, y: 1024)); c.closePath(); c.fillPath()
        }
    case "Hexagons":
        background(0xE7D7AC)
        let palette: [UInt32] = [0xAF824A, 0xCDA568, 0xEDD3A1, 0x8E683F]
        let radius: CGFloat = 154
        let height = sqrt(3)*radius
        for col in -1...5 { for row in -1...5 {
            let x = CGFloat(col)*radius*1.5
            let y = CGFloat(row)*height + (col % 2 == 0 ? 0 : height/2)
            let points = (0..<6).map { index in
                let angle = CGFloat(index)*CGFloat.pi/3
                return CGPoint(x: x+cos(angle)*(radius-5), y: y+sin(angle)*(radius-5))
            }
            polygon(points, palette[((col+row*2)%4+4)%4])
        } }
    case "Mosaic":
        background(0xE8D6B9)
        let palette: [UInt32] = [0xE8D6B9, 0xC1745A, 0x3A6266, 0x89A79B]
        for row in 0..<4 { for col in 0..<4 {
            let x = CGFloat(col)*256, y = CGFloat(row)*256
            let index = row*3+col
            rect(x, y, 256, 256, 0, palette[index % 4])
            c.saveGState(); c.clip(to: CGRect(x: x, y: y, width: 256, height: 256))
            let corner = (row+col*3) % 4
            circle(x + (corner == 1 || corner == 2 ? 256 : 0), y + (corner >= 2 ? 256 : 0), 256, palette[(index+1) % 4])
            c.restoreGState()
        } }
    default: fatalError("Unknown artwork: \(name)")
    }
    return c.makeImage()!
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appending(path: "patternlock/Assets.xcassets")
func write(_ image: CGImage, to url: URL) throws {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}
func contents(_ images: [[String: String]], in directory: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
    try data.write(to: directory.appending(path: "Contents.json"))
}
for name in names {
    if name != "Classic" {
        let directory = assets.appending(path: "AppIcon" + name + ".appiconset")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(render(name, pixels: 1024), to: directory.appending(path: "AppIcon.png"))
        try contents([["filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]], in: directory)
    }
    let preview = assets.appending(path: "IconPreview" + name + ".imageset")
    try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
    try write(render(name, pixels: 256), to: preview.appending(path: "Preview.png"))
    try contents([["filename": "Preview.png", "idiom": "universal"]], in: preview)
    print(name)
}
