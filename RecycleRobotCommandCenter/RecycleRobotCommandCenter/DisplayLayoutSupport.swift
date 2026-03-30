import Cocoa
import CoreGraphics

struct DisplaySnapshot: Codable, Equatable {
    let name: String
    let identifier: String?
    let displayID: Int?
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let isPrimary: Bool

    var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    init(
        name: String,
        identifier: String? = nil,
        displayID: Int? = nil,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        isPrimary: Bool
    ) {
        self.name = name
        self.identifier = identifier
        self.displayID = displayID
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isPrimary = isPrimary
    }

    init(screen: NSScreen, isPrimary: Bool) {
        let displayID = DisplayLayoutSupport.displayID(for: screen)
        let frame = screen.frame

        self.init(
            name: screen.localizedName,
            identifier: DisplayLayoutSupport.displayUUIDString(for: displayID),
            displayID: displayID.map(Int.init),
            x: Double(frame.origin.x),
            y: Double(frame.origin.y),
            width: Double(frame.size.width),
            height: Double(frame.size.height),
            isPrimary: isPrimary
        )
    }
}

struct ActiveDisplay {
    let snapshot: DisplaySnapshot
    let frame: CGRect
}

enum DisplayLayoutSupport {
    static func isLikelySidecarDisplayName(_ name: String?) -> Bool {
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !normalizedName.isEmpty else { return false }
        return normalizedName.contains("sidecar") || normalizedName.contains("airplay")
    }

    static func isGenericSidecarDisplayName(_ name: String?) -> Bool {
        isLikelySidecarDisplayName(name)
    }

    static func currentDisplays() -> [DisplaySnapshot] {
        activeDisplays().map(\.snapshot)
    }

    static func activeDisplays() -> [ActiveDisplay] {
        NSScreen.screens.enumerated().map { index, screen in
            let snapshot = DisplaySnapshot(screen: screen, isPrimary: index == 0)
            return ActiveDisplay(snapshot: snapshot, frame: screen.frame)
        }
    }

    static func bestDisplay(for windowFrame: CGRect, among displays: [ActiveDisplay]) -> ActiveDisplay? {
        guard !displays.isEmpty else { return nil }

        let intersectionWinner = displays.max { lhs, rhs in
            intersectionArea(windowFrame, lhs.frame) < intersectionArea(windowFrame, rhs.frame)
        }

        if let intersectionWinner, intersectionArea(windowFrame, intersectionWinner.frame) > 0 {
            return intersectionWinner
        }

        let windowCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        return displays.min { lhs, rhs in
            distanceBetween(windowCenter, and: center(of: lhs.frame)) <
            distanceBetween(windowCenter, and: center(of: rhs.frame))
        }
    }

    static func normalizedFrame(for windowFrame: CGRect, in displayFrame: CGRect) -> CGRect? {
        guard displayFrame.width > 0, displayFrame.height > 0 else { return nil }

        return CGRect(
            x: (windowFrame.origin.x - displayFrame.origin.x) / displayFrame.width,
            y: (windowFrame.origin.y - displayFrame.origin.y) / displayFrame.height,
            width: windowFrame.width / displayFrame.width,
            height: windowFrame.height / displayFrame.height
        )
    }

    static func denormalizedFrame(from normalizedFrame: CGRect, in displayFrame: CGRect) -> CGRect {
        CGRect(
            x: displayFrame.origin.x + (normalizedFrame.origin.x * displayFrame.width),
            y: displayFrame.origin.y + (normalizedFrame.origin.y * displayFrame.height),
            width: normalizedFrame.width * displayFrame.width,
            height: normalizedFrame.height * displayFrame.height
        )
    }

    static func matchingDisplay(
        identifier: String?,
        displayID: Int?,
        name: String?,
        among displays: [ActiveDisplay]
    ) -> ActiveDisplay? {
        if let identifier {
            if let match = displays.first(where: { $0.snapshot.identifier == identifier }) {
                return match
            }
        }

        if let displayID {
            if let match = displays.first(where: { $0.snapshot.displayID == displayID }) {
                return match
            }
        }

        if let name {
            if let exactMatch = displays.first(where: { $0.snapshot.name == name }) {
                return exactMatch
            }

            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalizedName.isEmpty {
                return displays.first {
                    $0.snapshot.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedName
                }
            }
        }

        return nil
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }

    static func displayUUIDString(for displayID: CGDirectDisplayID?) -> String? {
        guard let displayID,
              let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID) else {
            return nil
        }

        let uuid = unmanagedUUID.takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }

    private static func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private static func distanceBetween(_ lhs: CGPoint, and rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}
