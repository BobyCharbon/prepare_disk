// Dessine l'icône de Prepare Disk (1024 × 1024) : un disque externe avec ses partitions
// (3 macOS + données) et une flèche de téléchargement.
// Usage : swift Icon/make_icon.swift Icon/AppIcon.png
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [])
    ctx.restoreGState()
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext

// Fond : carré arrondi façon macOS (824 px dans la grille de 1024), dégradé bleu nuit.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let background = rounded(body, 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(background)
ctx.setFillColor(color(0x1B2A6B))
ctx.fillPath()
ctx.restoreGState()
gradient(ctx, background, [color(0x4C8DFF), color(0x2346C8), color(0x14205E)],
         from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
// Reflet doux en haut.
gradient(ctx, background, [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)],
         from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 600))

// Disque : boîtier clair avec ombre portée.
let drive = CGRect(x: 214, y: 250, width: 596, height: 300)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: color(0x000000, 0.45))
ctx.addPath(rounded(drive, 64))
ctx.setFillColor(color(0xE9EDF5))
ctx.fillPath()
ctx.restoreGState()
gradient(ctx, rounded(drive, 64), [color(0xFFFFFF), color(0xD5DBE8)],
         from: CGPoint(x: 512, y: drive.maxY), to: CGPoint(x: 512, y: drive.minY))
// Tranche du dessus, un peu plus claire.
gradient(ctx, rounded(drive.insetBy(dx: 10, dy: 10), 56), [color(0xFFFFFF, 0.9), color(0xFFFFFF, 0)],
         from: CGPoint(x: 512, y: drive.maxY), to: CGPoint(x: 512, y: drive.midY + 40))

// Barre des partitions : 3 macOS + DataExternalDrive.
let bar = CGRect(x: 270, y: 330, width: 400, height: 64)
ctx.saveGState()
ctx.addPath(rounded(bar, 32))
ctx.clip()
let segments: [(CGFloat, UInt32)] = [(0.2, 0x3478F6), (0.2, 0x8E5CF7), (0.2, 0xFF9F0A), (0.4, 0x8A93A6)]
var x = bar.minX
for (i, (fraction, hex)) in segments.enumerated() {
    let width = bar.width * fraction
    ctx.setFillColor(color(hex))
    ctx.fill(CGRect(x: x, y: bar.minY, width: width, height: bar.height))
    ctx.setFillColor(color(0xFFFFFF))
    if i < segments.count - 1 { ctx.fill(CGRect(x: x + width - 3, y: bar.minY, width: 6, height: bar.height)) }
    x += width
}
ctx.restoreGState()

// Voyant d'activité, vert.
let led = CGRect(x: 712, y: 340, width: 44, height: 44)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18, color: color(0x30D158, 0.9))
ctx.setFillColor(color(0x30D158))
ctx.fillEllipse(in: led)
ctx.restoreGState()

// Pastille de téléchargement posée sur le disque.
let badge = CGRect(x: 512 - 140, y: 500, width: 280, height: 280)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: color(0x000000, 0.4))
ctx.setFillColor(color(0x30C35A))
ctx.fillEllipse(in: badge)
ctx.restoreGState()
gradient(ctx, CGPath(ellipseIn: badge, transform: nil), [color(0x5EE07F), color(0x1FA347)],
         from: CGPoint(x: 512, y: badge.maxY), to: CGPoint(x: 512, y: badge.minY))
ctx.setStrokeColor(color(0xFFFFFF, 0.9))
ctx.setLineWidth(10)
ctx.strokeEllipse(in: badge.insetBy(dx: 5, dy: 5))

// Flèche blanche vers le bas.
let arrow = CGMutablePath()
arrow.move(to: CGPoint(x: 512, y: 728))
arrow.addLine(to: CGPoint(x: 512, y: 560))
arrow.move(to: CGPoint(x: 444, y: 628))
arrow.addLine(to: CGPoint(x: 512, y: 560))
arrow.addLine(to: CGPoint(x: 580, y: 628))
ctx.addPath(arrow)
ctx.setStrokeColor(color(0xFFFFFF))
ctx.setLineWidth(40)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("OK : \(output)")
