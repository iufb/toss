// Рисует иконку приложения (вариант «Графит») и собирает AppIcon.icns.
// Запуск: swift make_icon.swift   (нужно только при изменении иконки)

import AppKit

func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
            green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: a)
}

/// Рисует иконку в координатах 1024×1024 (начало — левый верхний угол).
func drawIcon(_ ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Тело иконки с тенью
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 28, color: hex(0x000000, 0.35))
    ctx.addPath(body); ctx.setFillColor(hex(0x15161a)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    let bg = CGGradient(colorsSpace: space, colors: [hex(0x454952), hex(0x15161a)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()

    // Наушники: оголовье + чашки, залитые градиентом «шампанское»
    let band = CGMutablePath()
    band.move(to: CGPoint(x: 290, y: 560))
    band.addLine(to: CGPoint(x: 290, y: 510))
    band.addArc(center: CGPoint(x: 512, y: 510), radius: 222,
                startAngle: .pi, endAngle: 0, clockwise: false)
    band.addLine(to: CGPoint(x: 734, y: 560))
    // Каждую часть заливаем отдельно: при общем пути пересечения дают дырки
    let parts: [CGPath] = [
        band.copy(strokingWithWidth: 58, lineCap: .round, lineJoin: .round, miterLimit: 10),
        CGPath(roundedRect: CGRect(x: 236, y: 520, width: 132, height: 222), cornerWidth: 58, cornerHeight: 58, transform: nil),
        CGPath(roundedRect: CGRect(x: 656, y: 520, width: 132, height: 222), cornerWidth: 58, cornerHeight: 58, transform: nil),
    ]
    let gold = CGGradient(colorsSpace: space, colors: [hex(0xf6ead3), hex(0xcdb48c)] as CFArray, locations: [0, 1])!
    for part in parts {
        ctx.saveGState()
        ctx.addPath(part); ctx.clip()
        ctx.drawLinearGradient(gold, start: CGPoint(x: 512, y: 259), end: CGPoint(x: 512, y: 742),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    // Стрелки туда-обратно между чашками
    let arrows = CGMutablePath()
    arrows.move(to: CGPoint(x: 440, y: 600)); arrows.addLine(to: CGPoint(x: 590, y: 600))
    arrows.move(to: CGPoint(x: 560, y: 568)); arrows.addLine(to: CGPoint(x: 594, y: 600)); arrows.addLine(to: CGPoint(x: 560, y: 632))
    arrows.move(to: CGPoint(x: 590, y: 680)); arrows.addLine(to: CGPoint(x: 440, y: 680))
    arrows.move(to: CGPoint(x: 466, y: 648)); arrows.addLine(to: CGPoint(x: 432, y: 680)); arrows.addLine(to: CGPoint(x: 466, y: 712))
    ctx.addPath(arrows)
    ctx.setStrokeColor(hex(0xe8d6b4)); ctx.setLineWidth(30)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.strokePath()
}

func png(size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size) / 1024
    ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: s, y: -s)   // начало сверху слева
    drawIcon(ctx)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = dir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(size: 1024).write(to: dir.appendingPathComponent("AppIcon-preview.png"))
print("Готово: \(iconset.path)")
