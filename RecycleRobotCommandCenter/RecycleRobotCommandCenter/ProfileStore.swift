import Foundation

struct SidecarProfileTarget {
    let displayName: String
    let displayIdentifier: String?
    let displayID: Int?
    let deviceName: String?
}

struct WindowSnapshot: Codable {
    let appName: String
    let bundleIdentifier: String?
    let windowTitle: String
    let windowIndex: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let displayName: String?
    let displayIdentifier: String?
    let displayID: Int?
    let relativeX: Double?
    let relativeY: Double?
    let relativeWidth: Double?
    let relativeHeight: Double?

    var hasDisplayAssignment: Bool {
        displayName != nil || displayIdentifier != nil || displayID != nil
    }

    var hasRelativeFrame: Bool {
        relativeX != nil && relativeY != nil && relativeWidth != nil && relativeHeight != nil
    }

    init(
        appName: String,
        bundleIdentifier: String?,
        windowTitle: String,
        windowIndex: Int,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        displayName: String? = nil,
        displayIdentifier: String? = nil,
        displayID: Int? = nil,
        relativeX: Double? = nil,
        relativeY: Double? = nil,
        relativeWidth: Double? = nil,
        relativeHeight: Double? = nil
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.windowIndex = windowIndex
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.displayName = displayName
        self.displayIdentifier = displayIdentifier
        self.displayID = displayID
        self.relativeX = relativeX
        self.relativeY = relativeY
        self.relativeWidth = relativeWidth
        self.relativeHeight = relativeHeight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appName = try container.decode(String.self, forKey: .appName)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        windowTitle = try container.decode(String.self, forKey: .windowTitle)
        windowIndex = try container.decodeIfPresent(Int.self, forKey: .windowIndex) ?? 0
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        width = try container.decode(Double.self, forKey: .width)
        height = try container.decode(Double.self, forKey: .height)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        displayIdentifier = try container.decodeIfPresent(String.self, forKey: .displayIdentifier)
        displayID = try container.decodeIfPresent(Int.self, forKey: .displayID)
        relativeX = try container.decodeIfPresent(Double.self, forKey: .relativeX)
        relativeY = try container.decodeIfPresent(Double.self, forKey: .relativeY)
        relativeWidth = try container.decodeIfPresent(Double.self, forKey: .relativeWidth)
        relativeHeight = try container.decodeIfPresent(Double.self, forKey: .relativeHeight)
    }
}

struct WindowProfile: Codable, Identifiable {
    let id: String
    var name: String
    var windows: [WindowSnapshot]
    let createdAt: Date
    var displays: [DisplaySnapshot]
    var sidecarTargetDisplayName: String?
    var sidecarTargetDisplayIdentifier: String?
    var sidecarTargetDisplayID: Int?
    var sidecarTargetDeviceName: String?

    var supportsDisplayAwareRestore: Bool {
        !displays.isEmpty || windows.contains { $0.hasDisplayAssignment || $0.hasRelativeFrame }
    }

    var legacyRestoreMessage: String? {
        supportsDisplayAwareRestore ? nil : "Tip: re-save this profile to enable automatic Sidecar reconnect."
    }

    init(name: String, windows: [WindowSnapshot], displays: [DisplaySnapshot] = [], sidecarTargetDisplay: DisplaySnapshot? = nil) {
        self.id = UUID().uuidString
        self.name = name
        self.windows = windows
        self.createdAt = Date()
        self.displays = displays
        self.sidecarTargetDisplayName = sidecarTargetDisplay?.name
        self.sidecarTargetDisplayIdentifier = sidecarTargetDisplay?.identifier
        self.sidecarTargetDisplayID = sidecarTargetDisplay?.displayID
        self.sidecarTargetDeviceName = nil
    }

    init(
        name: String,
        windows: [WindowSnapshot],
        displays: [DisplaySnapshot],
        sidecarTargetDisplay: DisplaySnapshot?,
        sidecarTargetDeviceName: String?
    ) {
        self.id = UUID().uuidString
        self.name = name
        self.windows = windows
        self.createdAt = Date()
        self.displays = displays
        self.sidecarTargetDisplayName = sidecarTargetDisplay?.name
        self.sidecarTargetDisplayIdentifier = sidecarTargetDisplay?.identifier
        self.sidecarTargetDisplayID = sidecarTargetDisplay?.displayID
        self.sidecarTargetDeviceName = sidecarTargetDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        windows = try container.decode([WindowSnapshot].self, forKey: .windows)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        displays = try container.decodeIfPresent([DisplaySnapshot].self, forKey: .displays) ?? []
        sidecarTargetDisplayName = try container.decodeIfPresent(String.self, forKey: .sidecarTargetDisplayName)
        sidecarTargetDisplayIdentifier = try container.decodeIfPresent(String.self, forKey: .sidecarTargetDisplayIdentifier)
        sidecarTargetDisplayID = try container.decodeIfPresent(Int.self, forKey: .sidecarTargetDisplayID)
        sidecarTargetDeviceName = try container.decodeIfPresent(String.self, forKey: .sidecarTargetDeviceName)
    }

    var resolvedSidecarTarget: SidecarProfileTarget? {
        if let explicitDisplayName = sidecarTargetDisplayName,
           DisplayLayoutSupport.isLikelySidecarDisplayName(explicitDisplayName) || sidecarTargetDeviceName?.nilIfEmpty != nil {
            return SidecarProfileTarget(
                displayName: explicitDisplayName,
                displayIdentifier: sidecarTargetDisplayIdentifier,
                displayID: sidecarTargetDisplayID,
                deviceName: sidecarTargetDeviceName?.nilIfEmpty
            )
        }

        if let inferredDisplay = inferredSidecarDisplay {
            return SidecarProfileTarget(
                displayName: inferredDisplay.name,
                displayIdentifier: inferredDisplay.identifier,
                displayID: inferredDisplay.displayID,
                deviceName: sidecarTargetDeviceName?.nilIfEmpty
            )
        }

        return nil
    }

    private var inferredSidecarDisplay: DisplaySnapshot? {
        let displayCandidates = displays.filter { display in
            !display.isPrimary && DisplayLayoutSupport.isLikelySidecarDisplayName(display.name)
        }

        if displayCandidates.count == 1 {
            return displayCandidates[0]
        }

        let windowCandidates = windows.compactMap { window -> DisplaySnapshot? in
            guard DisplayLayoutSupport.isLikelySidecarDisplayName(window.displayName) else { return nil }

            return displays.first(where: {
                ($0.identifier != nil && $0.identifier == window.displayIdentifier) ||
                ($0.displayID != nil && $0.displayID == window.displayID) ||
                $0.name == window.displayName
            }) ?? DisplaySnapshot(
                name: window.displayName ?? "Sidecar Display",
                identifier: window.displayIdentifier,
                displayID: window.displayID,
                x: window.x,
                y: window.y,
                width: window.width,
                height: window.height,
                isPrimary: false
            )
        }

        let uniqueCandidates = Dictionary(
            grouping: windowCandidates,
            by: {
                $0.identifier ??
                $0.displayID.map(String.init) ??
                $0.name
            }
        ).compactMap(\.value.first)

        return uniqueCandidates.count == 1 ? uniqueCandidates[0] : nil
    }
}

class ProfileStore {
    static let shared = ProfileStore()

    private let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("RecycleRobotCommandCenter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("profiles.json")
    }()

    private(set) var profiles: [WindowProfile] = []

    private init() {
        load()
    }

    func save(profile: WindowProfile) {
        profiles.append(profile)
        persist()
    }

    func delete(profileId: String) {
        profiles.removeAll { $0.id == profileId }
        persist()
    }

    func rename(profileId: String, newName: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        profiles[idx].name = newName
        persist()
    }

    func update(
        profileId: String,
        windows: [WindowSnapshot],
        displays: [DisplaySnapshot],
        sidecarTargetDisplay: DisplaySnapshot?,
        sidecarTargetDeviceName: String?
    ) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        profiles[idx].windows = windows
        profiles[idx].displays = displays
        profiles[idx].sidecarTargetDisplayName = sidecarTargetDisplay?.name
        profiles[idx].sidecarTargetDisplayIdentifier = sidecarTargetDisplay?.identifier
        profiles[idx].sidecarTargetDisplayID = sidecarTargetDisplay?.displayID
        profiles[idx].sidecarTargetDeviceName = sidecarTargetDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        persist()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            profiles = try JSONDecoder().decode([WindowProfile].self, from: data)
        } catch {
            NSLog("Failed to load profiles: \(error)")
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Failed to save profiles: \(error)")
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
