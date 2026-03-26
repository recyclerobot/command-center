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

            for (index, axWindow) in axWindows.enumerated() {
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
                    windowIndex: index,
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

        // Group snapshots by app key (bundleIdentifier or appName)
        var snapshotsByApp: [String: [WindowSnapshot]] = [:]
        for snapshot in profile.windows {
            let key = snapshot.bundleIdentifier ?? snapshot.appName
            snapshotsByApp[key, default: []].append(snapshot)
        }

        for (appKey, snapshots) in snapshotsByApp {
            // Find matching running app
            guard let app = runningApps.first(where: {
                if let appBundleId = $0.bundleIdentifier {
                    return appBundleId == appKey
                }
                return $0.localizedName == appKey
            }) else {
                skipped += snapshots.count
                continue
            }

            let pid = app.processIdentifier
            let appRef = AXUIElementCreateApplication(pid)
            var windowsValue: AnyObject?
            let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsValue)

            guard result == .success, let axWindows = windowsValue as? [AXUIElement] else {
                skipped += snapshots.count
                continue
            }

            var claimedWindowIndices = Set<Int>()   // indices into axWindows already matched
            var matchedSnapshotIndices = Set<Int>()  // indices into snapshots already matched

            // Pass 1: Match by exact window title (first match wins, no double-claiming)
            for (si, snapshot) in snapshots.enumerated() {
                for (wi, axWindow) in axWindows.enumerated() {
                    if claimedWindowIndices.contains(wi) { continue }
                    guard let title = axAttribute(axWindow, kAXTitleAttribute) as? String else { continue }
                    if title == snapshot.windowTitle {
                        setWindowPosition(axWindow, x: snapshot.x, y: snapshot.y)
                        setWindowSize(axWindow, width: snapshot.width, height: snapshot.height)
                        claimedWindowIndices.insert(wi)
                        matchedSnapshotIndices.insert(si)
                        restored += 1
                        break
                    }
                }
            }

            // Pass 2: Match remaining snapshots by stored windowIndex
            for (si, snapshot) in snapshots.enumerated() {
                if matchedSnapshotIndices.contains(si) { continue }
                let wi = snapshot.windowIndex
                if wi < axWindows.count && !claimedWindowIndices.contains(wi) {
                    let axWindow = axWindows[wi]
                    setWindowPosition(axWindow, x: snapshot.x, y: snapshot.y)
                    setWindowSize(axWindow, width: snapshot.width, height: snapshot.height)
                    claimedWindowIndices.insert(wi)
                    matchedSnapshotIndices.insert(si)
                    restored += 1
                }
            }

            // Pass 3: Match remaining snapshots to any unclaimed windows
            var unclaimed = (0..<axWindows.count).filter { !claimedWindowIndices.contains($0) }
            for (si, snapshot) in snapshots.enumerated() {
                if matchedSnapshotIndices.contains(si) { continue }
                if let wi = unclaimed.first {
                    let axWindow = axWindows[wi]
                    setWindowPosition(axWindow, x: snapshot.x, y: snapshot.y)
                    setWindowSize(axWindow, width: snapshot.width, height: snapshot.height)
                    unclaimed.removeFirst()
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
