import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let appSet = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
let docSet = FileManager.default.temporaryDirectory.appendingPathComponent("elck-doc.iconset")

func hex(_ rgb: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
        green: CGFloat((rgb >> 8) & 0xFF) / 255,
        blue: CGFloat(rgb & 0xFF) / 255,
        alpha: a
    )
}

func context(_ n: Int) -> CGContext {
    let ctx = CGContext(
        data: nil,
        width: n,
        height: n,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    return ctx
}

func seal(in ctx: CGContext, center: CGPoint, radius: CGFloat) {
    let box = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    ctx.saveGState()
    ctx.addEllipse(in: box)
    ctx.clip()
    let colors = [hex(0xFFE7B0), hex(0xE2B04A), hex(0x8C5A22)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(
        gradient,
        startCenter: CGPoint(x: center.x - radius * 0.28, y: center.y + radius * 0.32),
        startRadius: 0,
        endCenter: center,
        endRadius: radius * 1.15,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    ctx.setStrokeColor(hex(0x6B4316, 0.72))
    ctx.setLineWidth(radius * 0.055)
    ctx.strokeEllipse(in: box.insetBy(dx: radius * 0.11, dy: radius * 0.11))

    let headR = radius * 0.20
    let headCY = center.y + radius * 0.10
    let hole = CGMutablePath()
    let neck = radius * 0.09
    let belly = radius * 0.20
    let topY = headCY - headR * 0.2
    let botY = center.y - radius * 0.40
    hole.move(to: CGPoint(x: center.x - neck, y: topY))
    hole.addLine(to: CGPoint(x: center.x + neck, y: topY))
    hole.addLine(to: CGPoint(x: center.x + belly, y: botY + radius * 0.08))
    hole.addQuadCurve(
        to: CGPoint(x: center.x - belly, y: botY + radius * 0.08),
        control: CGPoint(x: center.x, y: botY - radius * 0.02)
    )
    hole.closeSubpath()
    ctx.setFillColor(hex(0x24180C))
    ctx.fillEllipse(in: CGRect(x: center.x - headR, y: headCY - headR, width: headR * 2, height: headR * 2))
    ctx.addPath(hole)
    ctx.fillPath()
}

func drawApp(_ ctx: CGContext, n: Int) {
    let s = CGFloat(n) / 1024
    let colors = [hex(0x2A3E52), hex(0x121920)] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(n)), end: CGPoint(x: 0, y: 0), options: [])
    seal(in: ctx, center: CGPoint(x: 512 * s, y: 524 * s), radius: 336 * s)
}

func drawDoc(_ ctx: CGContext, n: Int) {
    let s = CGFloat(n) / 1024
    let page = CGRect(x: 150 * s, y: 72 * s, width: 724 * s, height: 880 * s)
    let radius = 52 * s
    let fold = 168 * s
    let right = page.maxX
    let top = page.maxY
    let path = CGMutablePath()
    path.move(to: CGPoint(x: page.minX + radius, y: page.minY))
    path.addArc(tangent1End: CGPoint(x: right, y: page.minY), tangent2End: CGPoint(x: right, y: page.minY + radius), radius: radius)
    path.addLine(to: CGPoint(x: right, y: top - fold))
    path.addLine(to: CGPoint(x: right - fold, y: top))
    path.addArc(tangent1End: CGPoint(x: page.minX, y: top), tangent2End: CGPoint(x: page.minX, y: top - radius), radius: radius)
    path.addArc(tangent1End: CGPoint(x: page.minX, y: page.minY), tangent2End: CGPoint(x: page.minX + radius, y: page.minY), radius: radius)
    path.closeSubpath()

    ctx.addPath(path)
    ctx.setFillColor(hex(0xFBF9F4))
    ctx.fillPath()
    ctx.addPath(path)
    ctx.setStrokeColor(hex(0xDDD7CC))
    ctx.setLineWidth(max(1, 6 * s))
    ctx.strokePath()

    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: right, y: top - fold))
    flap.addLine(to: CGPoint(x: right - fold, y: top - fold))
    flap.addLine(to: CGPoint(x: right - fold, y: top))
    flap.closeSubpath()
    ctx.addPath(flap)
    ctx.setFillColor(hex(0xE6E0D4))
    ctx.fillPath()

    seal(in: ctx, center: CGPoint(x: page.midX, y: page.midY - 24 * s), radius: 228 * s)
}

func png(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "elck", code: 1)
    }
    try data.write(to: url)
}

let slots: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

try FileManager.default.createDirectory(at: appSet, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: docSet, withIntermediateDirectories: true)

for (name, n) in slots {
    let app = context(n)
    drawApp(app, n: n)
    try png(app.makeImage()!, to: appSet.appendingPathComponent(name))
    let doc = context(n)
    drawDoc(doc, n: n)
    try png(doc.makeImage()!, to: docSet.appendingPathComponent(name))
}

let catalog = """
{
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
let iconJSON = """
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try catalog.write(to: root.appendingPathComponent("Resources/Assets.xcassets/Contents.json"), atomically: true, encoding: .utf8)
try iconJSON.write(to: appSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print(appSet.path)
print(docSet.path)
