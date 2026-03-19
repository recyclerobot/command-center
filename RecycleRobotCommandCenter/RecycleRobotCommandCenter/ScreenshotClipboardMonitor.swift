import Cocoa

class ScreenshotClipboardMonitor {
    static let shared = ScreenshotClipboardMonitor()

    private var timer: Timer?
    private var lastChangeCount: Int = 0

    private let enabledKey = "screenshotSaveEnabled"
    private let folderKey = "screenshotSaveFolder"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue { start() } else { stop() }
        }
    }

    var saveFolder: String? {
        get { UserDefaults.standard.string(forKey: folderKey) }
        set { UserDefaults.standard.set(newValue, forKey: folderKey) }
    }

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
        if isEnabled { start() }
    }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // Check if the clipboard contains an image
        guard let types = pasteboard.types,
              types.contains(.tiff) || types.contains(.png) else {
            return
        }

        // Try to get the image data
        guard let image = NSImage(pasteboard: pasteboard) else { return }

        saveImageToFolder(image)
    }

    private func saveImageToFolder(_ image: NSImage) {
        guard let folder = saveFolder else { return }

        let folderURL = URL(fileURLWithPath: folder)

        // Ensure folder exists
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        // Generate filename with timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let timestamp = formatter.string(from: Date())
        let filename = "Screenshot \(timestamp).png"
        let fileURL = folderURL.appendingPathComponent(filename)

        // Avoid overwriting — append a counter if needed
        var finalURL = fileURL
        var counter = 1
        while FileManager.default.fileExists(atPath: finalURL.path) {
            let name = "Screenshot \(timestamp) (\(counter)).png"
            finalURL = folderURL.appendingPathComponent(name)
            counter += 1
        }

        // Convert to PNG and write
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            NSLog("Failed to convert clipboard image to PNG")
            return
        }

        do {
            try pngData.write(to: finalURL, options: .atomic)
            NSLog("Screenshot saved to \(finalURL.path)")
        } catch {
            NSLog("Failed to save screenshot: \(error)")
        }
    }
}
