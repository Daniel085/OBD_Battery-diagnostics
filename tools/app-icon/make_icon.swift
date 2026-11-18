// Draws the app icon (battery outline + health pulse on the app's teal) as a
// 1024x1024 opaque PNG. Run: swift tools/app-icon/make_icon.swift <out.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
// noneSkipLast: no alpha channel, which App Store icons require.
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let s = CGFloat(size)

// Background: diagonal teal gradient (seed colour 0xFF00695C in the middle).
let gradient = CGGradient(colorsSpace: space,
                          colors: [rgb(0x00897B), rgb(0x00695C), rgb(0x004D40)] as CFArray,
                          locations: [0, 0.5, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

// Battery body (horizontal), centred slightly left to balance the terminal.
let bodyW: CGFloat = 640, bodyH: CGFloat = 380, stroke: CGFloat = 46
let nubW: CGFloat = 54, nubH: CGFloat = 150, gap: CGFloat = 22
let totalW = bodyW + gap + nubW
let bodyX = (s - totalW) / 2, bodyY = (s - bodyH) / 2
let body = CGRect(x: bodyX, y: bodyY, width: bodyW, height: bodyH)

ctx.setStrokeColor(rgb(0xFFFFFF))
ctx.setLineWidth(stroke)
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: stroke / 2, dy: stroke / 2),
                   cornerWidth: 70, cornerHeight: 70, transform: nil))
ctx.strokePath()

// Terminal nub.
ctx.setFillColor(rgb(0xFFFFFF))
let nub = CGRect(x: bodyX + bodyW + gap, y: (s - nubH) / 2, width: nubW, height: nubH)
ctx.addPath(CGPath(roundedRect: nub, cornerWidth: 22, cornerHeight: 22, transform: nil))
ctx.fillPath()

// Health pulse inside the battery (CoreGraphics y grows upward).
let inner = body.insetBy(dx: stroke + 34, dy: stroke + 30)
let midY = inner.midY
func px(_ f: CGFloat) -> CGFloat { inner.minX + inner.width * f }
let amp = inner.height / 2
let pulse = CGMutablePath()
pulse.move(to: CGPoint(x: px(0.0), y: midY))
pulse.addLine(to: CGPoint(x: px(0.28), y: midY))
pulse.addLine(to: CGPoint(x: px(0.38), y: midY + amp * 0.95))
pulse.addLine(to: CGPoint(x: px(0.52), y: midY - amp * 0.95))
pulse.addLine(to: CGPoint(x: px(0.62), y: midY + amp * 0.35))
pulse.addLine(to: CGPoint(x: px(0.70), y: midY))
pulse.addLine(to: CGPoint(x: px(1.0), y: midY))
ctx.setStrokeColor(rgb(0xB2FF59))
ctx.setLineWidth(40)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.addPath(pulse)
ctx.strokePath()

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: out)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out)") }
print("wrote \(out)")
