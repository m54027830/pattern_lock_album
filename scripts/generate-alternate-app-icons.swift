#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO

// Original utility illustrations and abstract geometry for alternate app icons.
// App icons and full-resolution picker previews use the same drawing.
let names = ["Classic", "Square", "Triangles", "Checker", "Stripes", "Rings", "Diamonds", "Waves", "Hexagons", "Mosaic",
             "Calculator", "Printer", "WiFi", "Chatbot", "Notes", "Weather", "Clock", "Compass"]
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
    case "Classic", "ProPurchase", "SpecialPurchase":
        // Layers / Atmosphere: overlapping tiles on a muted, flowing backdrop.
        // Keep the Classic asset identifier for the existing default-icon picker.
        let isPurchase = name != "Classic"
        let isSpecial = name == "SpecialPurchase"
        let palette: [UInt32] = isPurchase ? [0x344C69, 0x223953, 0x14273E] : [0x92A3A2, 0x738B91, 0x526A77]
        let gradient = CGGradient(colorsSpace: space,
                                  colors: palette.map { color($0) } as CFArray,
                                  locations: [0, 0.5, 1])!
        c.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0),
                             end: CGPoint(x: 1024, y: 1024),
                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.saveGState()
        c.setAlpha(0.14)
        fill(0xD0D8CF)
        c.move(to: CGPoint(x: 0, y: 0))
        c.addLine(to: CGPoint(x: 1024, y: 0))
        c.addCurve(to: CGPoint(x: 0, y: 700), control1: CGPoint(x: 760, y: 270),
                   control2: CGPoint(x: 180, y: 210))
        c.closePath()
        c.fillPath()
        c.setAlpha(0.12)
        fill(0x334F62)
        c.move(to: CGPoint(x: 0, y: 1024))
        c.addLine(to: CGPoint(x: 1024, y: 1024))
        c.addLine(to: CGPoint(x: 1024, y: 440))
        c.addCurve(to: CGPoint(x: 0, y: 1024), control1: CGPoint(x: 750, y: 810),
                   control2: CGPoint(x: 360, y: 610))
        c.closePath()
        c.fillPath()
        c.restoreGState()
        rect(280, 280, 360, 360, 58, isPurchase ? (isSpecial ? 0xBA965B : 0x70889E) : 0xA6B4B5)
        rect(384, 384, 360, 360, 58, isPurchase ? (isSpecial ? 0xF8E7BE : 0xE0E6EA) : 0xDBE0DB)
        if isPurchase {
            // Both products unlock the same unlimited access: the same infinity mark.
            c.setStrokeColor(color(0x223953)); c.setLineWidth(24); c.setLineCap(.round)
            c.move(to: CGPoint(x: 564, y: 564))
            c.addCurve(to: CGPoint(x: 460, y: 564), control1: CGPoint(x: 510, y: 482), control2: CGPoint(x: 460, y: 504))
            c.addCurve(to: CGPoint(x: 564, y: 564), control1: CGPoint(x: 460, y: 624), control2: CGPoint(x: 510, y: 646))
            c.addCurve(to: CGPoint(x: 668, y: 564), control1: CGPoint(x: 618, y: 482), control2: CGPoint(x: 668, y: 504))
            c.addCurve(to: CGPoint(x: 564, y: 564), control1: CGPoint(x: 668, y: 624), control2: CGPoint(x: 618, y: 646))
            c.strokePath()
        }
        if isSpecial {
            // A price-tag badge identifies the offer without embedding a price or deadline.
            polygon([CGPoint(x: 710, y: 268), CGPoint(x: 788, y: 268), CGPoint(x: 842, y: 322),
                     CGPoint(x: 748, y: 416), CGPoint(x: 672, y: 340)], 0xEBC778)
            circle(758, 308, 13, 0x223953)
        }
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
    case "Calculator":
        background(0x172E43, 0x2D4D64)
        rect(210, 140, 604, 744, 78, 0xE9EEE8)
        rect(266, 200, 492, 160, 26, 0xB7CDC7)
        line([CGPoint(x: 610, y: 254), CGPoint(x: 696, y: 254), CGPoint(x: 696, y: 306)], 14, 0x36585D)
        for row in 0..<3 { for col in 0..<3 {
            rect(266 + CGFloat(col)*176, 410 + CGFloat(row)*142, 140, 110, 30, col == 2 ? 0xD9A65D : 0x486C79)
        } }
        line([CGPoint(x: 642, y: 452), CGPoint(x: 698, y: 452)], 12, 0xFFFFFF)
        line([CGPoint(x: 642, y: 478), CGPoint(x: 698, y: 478)], 12, 0xFFFFFF)
        line([CGPoint(x: 642, y: 607), CGPoint(x: 698, y: 607)], 12, 0xFFFFFF)
        line([CGPoint(x: 670, y: 579), CGPoint(x: 670, y: 635)], 12, 0xFFFFFF)
        line([CGPoint(x: 642, y: 749), CGPoint(x: 698, y: 749)], 12, 0xFFFFFF)
    case "Printer":
        background(0xE4EAE7, 0xBCD0CB)
        rect(292, 146, 440, 340, 24, 0xFFFFFF)
        line([CGPoint(x: 356, y: 234), CGPoint(x: 668, y: 234)], 20, 0xBCCEC8)
        line([CGPoint(x: 356, y: 296), CGPoint(x: 598, y: 296)], 20, 0xBCCEC8)
        rect(148, 364, 728, 376, 74, 0x365E58)
        rect(202, 418, 620, 76, 26, 0x4F7A71)
        circle(762, 456, 15, 0xE8BD78)
        rect(254, 582, 516, 122, 28, 0x203F3D)
        rect(292, 620, 440, 258, 20, 0xFFFFFF)
        line([CGPoint(x: 358, y: 700), CGPoint(x: 666, y: 700)], 20, 0xA1B8AF)
        line([CGPoint(x: 358, y: 764), CGPoint(x: 594, y: 764)], 20, 0xA1B8AF)
    case "WiFi":
        background(0x317B8D, 0x16465F)
        c.setStrokeColor(color(0xFFFFFF)); c.setLineWidth(60); c.setLineCap(.round)
        for (halfWidth, y, lift) in [(CGFloat(326), CGFloat(348), CGFloat(214)), (230, 498, 150), (126, 646, 82)] {
            c.move(to: CGPoint(x: 512-halfWidth, y: y))
            c.addCurve(to: CGPoint(x: 512+halfWidth, y: y), control1: CGPoint(x: 512-halfWidth/2, y: y-lift), control2: CGPoint(x: 512+halfWidth/2, y: y-lift))
            c.strokePath()
        }
        circle(512, 790, 47, 0xFFFFFF)
    case "Chatbot":
        background(0x7560A7, 0x433D70)
        line([CGPoint(x: 512, y: 202), CGPoint(x: 512, y: 288)], 24, 0xE2D9F5)
        circle(512, 182, 32, 0xE2D9F5)
        polygon([CGPoint(x: 302, y: 638), CGPoint(x: 306, y: 834), CGPoint(x: 480, y: 690)], 0xF5F2FB)
        rect(182, 274, 660, 470, 140, 0xF5F2FB)
        rect(266, 368, 492, 262, 86, 0xDAD4ED)
        rect(358, 430, 52, 80, 26, 0x554B7D)
        rect(614, 430, 52, 80, 26, 0x554B7D)
        line([CGPoint(x: 460, y: 564), CGPoint(x: 564, y: 564)], 22, 0x554B7D)
    case "Notes":
        background(0xEAC774, 0xD99C56)
        rect(182, 142, 660, 752, 52, 0xFFFCF0)
        rect(182, 142, 660, 154, 52, 0xF7E8B5)
        rect(182, 242, 660, 54, 0, 0xF7E8B5)
        line([CGPoint(x: 320, y: 338), CGPoint(x: 320, y: 820)], 12, 0xD78971)
        for y: CGFloat in [384, 488, 592, 696, 800] {
            line([CGPoint(x: 382, y: y), CGPoint(x: y == 800 ? 622 : 746, y: y)], 18, 0xC1C8BA)
        }
    case "Weather":
        background(0x6DA9CA, 0x356D9B)
        for index in 0..<8 {
            let angle = CGFloat(index)*CGFloat.pi/4
            line([CGPoint(x: 370+cos(angle)*182, y: 372+sin(angle)*182), CGPoint(x: 370+cos(angle)*222, y: 372+sin(angle)*222)], 22, 0xF9D786)
        }
        circle(370, 372, 132, 0xF9D786)
        circle(402, 608, 118, 0xEDF5F6)
        circle(562, 540, 154, 0xEDF5F6)
        circle(728, 626, 112, 0xEDF5F6)
        rect(292, 608, 548, 130, 65, 0xEDF5F6)
    case "Clock":
        background(0xDCE5E6, 0xB4C9CF)
        circle(512, 512, 344, 0x254650)
        circle(512, 512, 314, 0xF5F5EC)
        for index in 0..<12 {
            let angle = CGFloat(index)*CGFloat.pi/6
            let inner: CGFloat = index % 3 == 0 ? 254 : 270
            line([CGPoint(x: 512+cos(angle)*inner, y: 512+sin(angle)*inner), CGPoint(x: 512+cos(angle)*288, y: 512+sin(angle)*288)], index % 3 == 0 ? 16 : 10, 0x33525B)
        }
        line([CGPoint(x: 380, y: 362), CGPoint(x: 512, y: 512), CGPoint(x: 712, y: 512)], 28, 0x254650)
        line([CGPoint(x: 472, y: 590), CGPoint(x: 628, y: 286)], 10, 0xD58B5F)
        circle(512, 512, 26, 0xD58B5F)
    case "Compass":
        background(0x233E4F, 0x122936)
        circle(512, 512, 350, 0xA2BEC0)
        circle(512, 512, 326, 0xE7ECE3)
        for index in 0..<16 {
            let angle = CGFloat(index)*CGFloat.pi/8
            let inner: CGFloat = index % 4 == 0 ? 256 : 282
            line([CGPoint(x: 512+cos(angle)*inner, y: 512+sin(angle)*inner), CGPoint(x: 512+cos(angle)*304, y: 512+sin(angle)*304)], 12, 0x5C7A7D)
        }
        polygon([CGPoint(x: 618, y: 244), CGPoint(x: 586, y: 542), CGPoint(x: 438, y: 482)], 0xC97B63)
        polygon([CGPoint(x: 406, y: 780), CGPoint(x: 438, y: 482), CGPoint(x: 586, y: 542)], 0x3D6570)
        circle(512, 512, 35, 0xFAFCF7)
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
if CommandLine.arguments.contains("--purchase-icons") {
    let directory = root.appending(path: "output/app-store-purchases")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, filename) in [("ProPurchase", "pro-1024.png"), ("SpecialPurchase", "pro-special-offer-1024.png")] {
        try write(render(name, pixels: 1024), to: directory.appending(path: filename))
        print(directory.appending(path: filename).path)
    }
    exit(0)
}
let requestedNames = CommandLine.arguments.contains("--primary-only") ? ["Classic"] : names
for name in requestedNames {
    do {
        let assetName = name == "Classic" ? "AppIcon" : "AppIcon" + name
        let directory = assets.appending(path: assetName + ".appiconset")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(render(name, pixels: 1024), to: directory.appending(path: "AppIcon.png"))
        try contents([["filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]], in: directory)
    }
    let preview = assets.appending(path: "IconPreview" + name + ".imageset")
    try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
    // Full-resolution previews also export cleanly for a named Home Screen shortcut.
    try write(render(name, pixels: 1024), to: preview.appending(path: "Preview.png"))
    try contents([["filename": "Preview.png", "idiom": "universal"]], in: preview)
    print(name)
}
