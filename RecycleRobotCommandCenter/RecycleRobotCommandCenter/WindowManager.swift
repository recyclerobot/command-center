import Cocoa
import ApplicationServices

class WindowManager {
    static let shared = WindowManager()

    // MARK: - Capture current windows

    func captureWindows() -> [WindowSnapshot] {
        var snapshots: [WindowSnapshot] = []

        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        for app in runningApps {
            guard let appName = app.localizedName else { continue }
            let pid = app.processIdentifier
            let bundleId = app.bundleIdentifier

            let appRef = AXUIElementCreateApplication(pid)
            var windowsValue: AnyObject?
            let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsValue)

            guard result == .success, let axWindows = windowsValue as? [AXUIElement] else {
                continue
            }

            for axWindow in axWindows {
                guard let title = axAttribute(axWindow, kAXTitleAttribute) as? String else {
                    continue
                }

                // Skip windows with empty titles (e.g. hidden helper windows)
                if title.isEmpty { continue }

                var position = CGPoint.zero
                var size = CGSize.zero

                if let posValue = axAttribute(axWindow, kAXPositionAttribute) {
                    AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
                }
                if let sizeValue = axAttribute(axWindow, kAXSizeAttribute) {
                    AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                }

                let snapshot = WindowSnapshot(
                    appName: appName,
                    bundleIdentifier: bundleId,
                    windowTitle: title,
                    x: Double(position.x),
                    y: Double(position.y),
                    width: Double(size.width),
                    height: Double(size.height)
                )
                snapshots.append(snapshot)
            }
        }

        return snapshots
    }

    // MARK: - Restore windows from profile

    func restoreWindows(from profile: WindowProfile) -> (restored: Int, skipped: Int) {
        var restored = 0
        var skipped = 0

        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        for snapshot in profile.windows {
            // Find matching running app by bundle identifier or name
            guard let app = runningApps.first(where: {
                if let bundleId = snapshot.bundleIdentifier, let appBundleId = $0.bundleIdentifier {
                    return bundleId == appBundleId
                }
                return $0.localizedName == snapshot.appName
            }) else {
                skipped += 1
                continue
            }

            let pid = app.processIdentifier
            let appRef = AXUIElementCreateApplication(pid)
            var windowsValue: AnyObject?
            let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsValue)

            guard result == .success, let axWindows = windowsValue as? [AXUIElement] else {
                skipped += 1
                continue
            }

            // Find matching window by title
            var found = false
            for axWindow in axWindows {
                guard let title = axAttribute(axWindow, kAXTitleAttribute) as? String else {
                    continue
                }

                if title == snapshot.windowTitle {
                    setWindowPosition(axWindow, x: snapshot.x, y: snapshot.y)
                    setWindowSize(axWindow, width: snapshot.width, height: snapshot.height)
                    restored += 1
                    found = true
                    break
                }
            }

            // If exact title not found, try to position the first window of the app
            if !found {
                if let firstWindow = axWindows.first {
                    setWindowPosition(firstWindow, x: snapshot.x, y: snapshot.y)
                    setWindowSize(firstWindow, width: snapshot.width, height: snapshot.height)
                    restored += 1
                } else {
                    skipped += 1
                }
            }
        }

        return (restored, skipped)
    }

    // MARK: - Accessibility Helpers

    private func axAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return result == .success ? value : nil
    }

    private func setWindowPosition(_ window: AXUIElement, x: Double, y: Double) {
        var point = CGPoint(x: x, y: y)
        guard let positionValue = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
    }

    private func setWindowSize(_ window: AXUIElement, width: Double, height: Double) {
        var size = CGSize(width: width, height: height)
        guard let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
    }
}
