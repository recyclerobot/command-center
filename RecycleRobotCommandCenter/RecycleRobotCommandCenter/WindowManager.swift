import Cocoa
import ApplicationServices

struct WindowRestoreResult {
    let restored: Int
    let skippedAppNotRunning: Int
    let skippedDisplayUnavailable: Int
    let sidecarConnection: SidecarConnectionResult?

    var skippedTotal: Int {
        skippedAppNotRunning + skippedDisplayUnavailable
    }
}

class WindowManager {
    static let shared = WindowManager()

    private let sidecarService = SidecarAutomationService.shared

    func currentDisplays() -> [DisplaySnapshot] {
        DisplayLayoutSupport.currentDisplays()
    }

    // MARK: - Capture current windows

    func captureWindows() -> [WindowSnapshot] {
        var snapshots: [WindowSnapshot] = []
        let activeDisplays = DisplayLayoutSupport.activeDisplays()

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

                let windowFrame = CGRect(x: position.x, y: position.y, width: size.width, height: size.height)
                let bestDisplay = DisplayLayoutSupport.bestDisplay(for: windowFrame, among: activeDisplays)
                let relativeFrame = bestDisplay.flatMap {
                    DisplayLayoutSupport.normalizedFrame(for: windowFrame, in: $0.frame)
                }

                let snapshot = WindowSnapshot(
                    appName: appName,
                    bundleIdentifier: bundleId,
                    windowTitle: title,
                    windowIndex: index,
                    x: Double(position.x),
                    y: Double(position.y),
                    width: Double(size.width),
                    height: Double(size.height),
                    displayName: bestDisplay?.snapshot.name,
                    displayIdentifier: bestDisplay?.snapshot.identifier,
                    displayID: bestDisplay?.snapshot.displayID,
                    relativeX: relativeFrame.map { Double($0.origin.x) },
                    relativeY: relativeFrame.map { Double($0.origin.y) },
                    relativeWidth: relativeFrame.map { Double($0.size.width) },
                    relativeHeight: relativeFrame.map { Double($0.size.height) }
                )
                snapshots.append(snapshot)
            }
        }

        return snapshots
    }

    // MARK: - Restore windows from profile

    func restoreWindows(from profile: WindowProfile) -> WindowRestoreResult {
        var restored = 0
        var skippedAppNotRunning = 0
        var skippedDisplayUnavailable = 0
        var activeDisplays = DisplayLayoutSupport.activeDisplays()
        var sidecarConnection: SidecarConnectionResult?

        if let sidecarTarget = profile.resolvedSidecarTarget,
           DisplayLayoutSupport.matchingDisplay(
                identifier: sidecarTarget.displayIdentifier,
                displayID: sidecarTarget.displayID,
                name: sidecarTarget.displayName,
                among: activeDisplays
           ) == nil {
            sidecarConnection = sidecarService.ensureDisplayAvailable(
                targetDisplayName: sidecarTarget.displayName,
                targetDeviceName: sidecarTarget.deviceName,
                targetDisplayIdentifier: sidecarTarget.displayIdentifier,
                targetDisplayID: sidecarTarget.displayID
            )
            activeDisplays = DisplayLayoutSupport.activeDisplays()
        }

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
                skippedAppNotRunning += snapshots.count
                continue
            }

            let pid = app.processIdentifier
            let appRef = AXUIElementCreateApplication(pid)
            var windowsValue: AnyObject?
            let result = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsValue)

            guard result == .success, let axWindows = windowsValue as? [AXUIElement] else {
                skippedAppNotRunning += snapshots.count
                continue
            }

            let preparedSnapshots = snapshots.compactMap { snapshot -> PreparedWindowSnapshot? in
                guard let targetFrame = targetFrame(for: snapshot, activeDisplays: activeDisplays) else {
                    skippedDisplayUnavailable += 1
                    return nil
                }

                return PreparedWindowSnapshot(snapshot: snapshot, targetFrame: targetFrame)
            }

            var claimedWindowIndices = Set<Int>()   // indices into axWindows already matched
            var matchedSnapshotIndices = Set<Int>()  // indices into preparedSnapshots already matched

            // Pass 1: Match by exact window title (first match wins, no double-claiming)
            for (si, preparedSnapshot) in preparedSnapshots.enumerated() {
                for (wi, axWindow) in axWindows.enumerated() {
                    if claimedWindowIndices.contains(wi) { continue }
                    guard let title = axAttribute(axWindow, kAXTitleAttribute) as? String else { continue }
                    if title == preparedSnapshot.snapshot.windowTitle {
                        applyPreparedSnapshot(preparedSnapshot, to: axWindow)
                        claimedWindowIndices.insert(wi)
                        matchedSnapshotIndices.insert(si)
                        restored += 1
                        break
                    }
                }
            }

            // Pass 2: Match remaining snapshots by stored windowIndex
            for (si, preparedSnapshot) in preparedSnapshots.enumerated() {
                if matchedSnapshotIndices.contains(si) { continue }
                let wi = preparedSnapshot.snapshot.windowIndex
                if wi < axWindows.count && !claimedWindowIndices.contains(wi) {
                    let axWindow = axWindows[wi]
                    applyPreparedSnapshot(preparedSnapshot, to: axWindow)
                    claimedWindowIndices.insert(wi)
                    matchedSnapshotIndices.insert(si)
                    restored += 1
                }
            }

            // Pass 3: Match remaining snapshots to any unclaimed windows
            var unclaimed = (0..<axWindows.count).filter { !claimedWindowIndices.contains($0) }
            for (si, preparedSnapshot) in preparedSnapshots.enumerated() {
                if matchedSnapshotIndices.contains(si) { continue }
                if let wi = unclaimed.first {
                    let axWindow = axWindows[wi]
                    applyPreparedSnapshot(preparedSnapshot, to: axWindow)
                    unclaimed.removeFirst()
                    restored += 1
                } else {
                    skippedAppNotRunning += 1
                }
            }
        }

        return WindowRestoreResult(
            restored: restored,
            skippedAppNotRunning: skippedAppNotRunning,
            skippedDisplayUnavailable: skippedDisplayUnavailable,
            sidecarConnection: sidecarConnection
        )
    }

    // MARK: - Accessibility Helpers

    private func applyPreparedSnapshot(_ preparedSnapshot: PreparedWindowSnapshot, to window: AXUIElement) {
        let frame = preparedSnapshot.targetFrame
        setWindowPosition(window, x: Double(frame.origin.x), y: Double(frame.origin.y))
        setWindowSize(window, width: Double(frame.size.width), height: Double(frame.size.height))
    }

    private func targetFrame(for snapshot: WindowSnapshot, activeDisplays: [ActiveDisplay]) -> CGRect? {
        if snapshot.hasDisplayAssignment {
            guard let matchedDisplay = DisplayLayoutSupport.matchingDisplay(
                identifier: snapshot.displayIdentifier,
                displayID: snapshot.displayID,
                name: snapshot.displayName,
                among: activeDisplays
            ) else {
                return nil
            }

            if snapshot.hasRelativeFrame,
               let relativeX = snapshot.relativeX,
               let relativeY = snapshot.relativeY,
               let relativeWidth = snapshot.relativeWidth,
               let relativeHeight = snapshot.relativeHeight {
                let normalizedFrame = CGRect(
                    x: relativeX,
                    y: relativeY,
                    width: relativeWidth,
                    height: relativeHeight
                )
                return DisplayLayoutSupport.denormalizedFrame(from: normalizedFrame, in: matchedDisplay.frame)
            }
        }

        return CGRect(x: snapshot.x, y: snapshot.y, width: snapshot.width, height: snapshot.height)
    }

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

private struct PreparedWindowSnapshot {
    let snapshot: WindowSnapshot
    let targetFrame: CGRect
}
