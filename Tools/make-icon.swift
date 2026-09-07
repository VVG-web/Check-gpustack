import AppKit

/// Рисует иконку приложения и собирает из неё .icns.
///
/// Кодом, а не в редакторе: иконку нужно отдать в десяти размерах от 16 до 1024, и
/// вручную это десять файлов, которые расходятся при первой же правке. Здесь рисунок
/// один, а размеры получаются из него.
///
///   swiftc -O Tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon Resources
///
/// Что нарисовано: тёмный сглаженный квадрат в стиле macOS, а на нём столбики
/// доступности — те же, что в окне истории. Один янтарный: монитор нужен не тогда, когда
/// всё зелено.

let sizes = [16, 32, 64, 128, 256, 512, 1024]

func draw(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Поле вокруг — как у всех системных иконок: без него значок кажется крупнее соседей.
    let pad = s * 0.094
    let box = NSRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let radius = box.width * 0.2237          // сглаживание угла, близкое к системному
    let plate = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)

    NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.19, blue: 0.24, alpha: 1),
                        NSColor(srgbRed: 0.06, green: 0.08, blue: 0.11, alpha: 1)])?
        .draw(in: plate, angle: -90)

    // Тонкая светлая кромка сверху: на тёмном фоне без неё плитка сливается с обоями.
    NSColor(white: 1, alpha: 0.10).setStroke()
    plate.lineWidth = max(1, s * 0.006)
    plate.stroke()

    // Столбики доступности. Четыре — предел, который ещё различим в 16 пикселей.
    let heights: [CGFloat] = [0.42, 0.66, 0.30, 0.86]
    let colors = [NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),
                  NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),
                  NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1),
                  NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)]
    let inner = box.insetBy(dx: box.width * 0.20, dy: box.height * 0.20)
    let gap = inner.width * 0.10
    let bw = (inner.width - gap * 3) / 4
    for i in 0..<4 {
        let h = inner.height * heights[i]
        let r = NSRect(x: inner.minX + CGFloat(i) * (bw + gap), y: inner.minY,
                       width: bw, height: h)
        colors[i].setFill()
        let cap = min(bw / 2, s * 0.03)
        NSBezierPath(roundedRect: r, xRadius: cap, yRadius: cap).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let fm = FileManager.default
let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

// Имена, которых ждёт iconutil: размер в точках плюс @2x для удвоенных.
let names: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
var cache: [Int: Data] = [:]
for (px, name) in names {
    if cache[px] == nil {
        cache[px] = draw(size: px).representation(using: .png, properties: [:])!
    }
    try! cache[px]!.write(to: iconset.appendingPathComponent(name))
}
print("Нарисовано размеров: \(Set(names.map { $0.0 }).count), файлов: \(names.count)")
