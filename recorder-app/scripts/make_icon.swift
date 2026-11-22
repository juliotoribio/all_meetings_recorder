// Dibuja el icono de la app (1024×1024) y genera AppIcon.icns.
//   swift recorder-app/scripts/make_icon.swift
// Forma y márgenes de la plantilla de iconos de macOS (cuadrado redondeado de 824 pt
// dentro de 1024); colores de la app: fondo grafito, onda en verde lima y punto de grabar.
import AppKit

let size: CGFloat = 1024
let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let out = root.appendingPathComponent("Resources")

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    // Sombra suave bajo la pieza, como los iconos del sistema.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x111111).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Fondo: grafito con un degradado sutil y un borde interior.
    NSGradient(starting: color(0x262626), ending: color(0x0C0C0C))!.draw(in: shape, angle: -90)
    color(0xFFFFFF, 0.07).setStroke()
    let rim = NSBezierPath(roundedRect: tile.insetBy(dx: 3, dy: 3), xRadius: 182, yRadius: 182)
    rim.lineWidth = 6
    rim.stroke()

    // Onda: cinco barras redondeadas en verde lima.
    let heights: [CGFloat] = [0.30, 0.58, 0.82, 0.50, 0.26]
    let barW: CGFloat = 74, gap: CGFloat = 46
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = tile.midX - total / 2
    let midY = tile.midY - 18
    for h in heights {
        let barH = 560 * h
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: midY - barH / 2, width: barW, height: barH),
                               xRadius: barW / 2, yRadius: barW / 2)
        NSGradient(starting: color(0xE2FB6E), ending: color(0xC6EA2A))!.draw(in: bar, angle: -90)
        x += barW + gap
    }

    // Punto de grabación arriba a la derecha.
    let dot = NSRect(x: tile.maxX - 208, y: tile.maxY - 208, width: 104, height: 104)
    color(0xFF5A4A).setFill()
    NSBezierPath(ovalIn: dot).fill()
    color(0xFFFFFF, 0.25).setStroke()
    let ring = NSBezierPath(ovalIn: dot.insetBy(dx: 2, dy: 2))
    ring.lineWidth = 4
    ring.stroke()
    return true
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func png(_ px: Int, _ name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}

for base in [16, 32, 128, 256, 512] {
    png(base, "icon_\(base)x\(base).png")
    png(base * 2, "icon_\(base)x\(base)@2x.png")
}
png(1024, "../AppIcon-1024.png")

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "✓ \(out.appendingPathComponent("AppIcon.icns").path)" : "✗ iconutil falló")
