import Cocoa

let sizes: [(Int, String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

for (pixelSize, filename) in sizes {
    let size = NSSize(width: pixelSize, height: pixelSize)
    let image = NSImage(size: size)
    image.lockFocus()

    // Background - rounded rect with gradient
    let bgRect = NSRect(origin: .zero, size: size)
    let path = NSBezierPath(roundedRect: bgRect, xRadius: CGFloat(pixelSize) * 0.2, yRadius: CGFloat(pixelSize) * 0.2)

    // Gradient background
    let gradient = NSGradient(starting: NSColor(red: 0.18, green: 0.8, blue: 0.44, alpha: 1.0),
                              ending: NSColor(red: 0.1, green: 0.6, blue: 0.35, alpha: 1.0))!
    gradient.draw(in: path, angle: -90)

    // Draw robot emoji
    let emoji = "🤖"
    let fontSize = CGFloat(pixelSize) * 0.7
    let font = NSFont.systemFont(ofSize: fontSize)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
    ]
    let textSize = emoji.size(withAttributes: attrs)
    let textRect = NSRect(
        x: (CGFloat(pixelSize) - textSize.width) / 2,
        y: (CGFloat(pixelSize) - textSize.height) / 2,
        width: textSize.width,
        height: textSize.height
    )
    emoji.draw(in: textRect, withAttributes: attrs)

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to generate \(filename)")
        continue
    }

    let url = URL(fileURLWithPath: outputDir).appendingPathComponent(filename)
    try! png.write(to: url)
    print("Generated \(filename) (\(pixelSize)x\(pixelSize))")
}

print("Done!")
