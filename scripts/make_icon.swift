// Draws DropForge's original icon and writes an .iconset folder.
// Usage: swift scripts/make_icon.swift <output.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // macOS icon grid: ~10 % margin, continuous-corner squircle.
    let inset = s * 0.1
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = CGPath(roundedRect: body, cornerWidth: body.width * 0.225, cornerHeight: body.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.35, blue: 0.40, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [CGColor(srgbRed: 0.08, green: 0.58, blue: 0.60, alpha: 1),
                                       CGColor(srgbRed: 0.20, green: 0.27, blue: 0.66, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Soft top light.
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.07))
    ctx.fillEllipse(in: CGRect(x: body.minX - body.width * 0.2, y: body.midY, width: body.width * 1.4, height: body.height))
    ctx.restoreGState()

    let c = CGPoint(x: s / 2, y: s / 2 - s * 0.01)
    let r = s * 0.235
    // Three ring segments with gaps (convert / tools / actions).
    let alphas: [CGFloat] = [1, 0.78, 0.56]
    for i in 0..<3 {
        let start = CGFloat.pi / 2 + CGFloat(i) * 2 * .pi / 3 + 0.2
        let end = start + 2 * .pi / 3 - 0.4
        ctx.setStrokeColor(CGColor(gray: 1, alpha: alphas[i]))
        ctx.setLineWidth(s * 0.075)
        ctx.setLineCap(.round)
        ctx.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: false)
        ctx.strokePath()
    }
    // Hub.
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - s * 0.07, y: c.y - s * 0.07, width: s * 0.14, height: s * 0.14))
    // Drop arrow coming down into the hub through the top gap.
    let top = c.y + r + s * 0.13
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(s * 0.05)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: c.x, y: top))
    ctx.addLine(to: CGPoint(x: c.x, y: c.y + s * 0.13))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: c.x - s * 0.06, y: c.y + s * 0.19))
    ctx.addLine(to: CGPoint(x: c.x, y: c.y + s * 0.13))
    ctx.addLine(to: CGPoint(x: c.x + s * 0.06, y: c.y + s * 0.19))
    ctx.strokePath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try render(px).write(to: out.appendingPathComponent("icon_\(name).png"))
}
print("wrote \(out.path)")
