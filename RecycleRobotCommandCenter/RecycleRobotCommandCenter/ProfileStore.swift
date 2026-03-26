import Foundation

struct WindowSnapshot: Codable {
    let appName: String
    let bundleIdentifier: String?
    let windowTitle: String
    let windowIndex: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(appName: String, bundleIdentifier: String?, windowTitle: String, windowIndex: Int, x: Double, y: Double, width: Double, height: Double) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.windowIndex = windowIndex
        self.x = x
        self.y = y
        self.width = width
        self.height = height
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
    }
}

struct WindowProfile: Codable, Identifiable {
    let id: String
    var name: String
    var windows: [WindowSnapshot]
    let createdAt: Date

    init(name: String, windows: [WindowSnapshot]) {
        self.id = UUID().uuidString
        self.name = name
        self.windows = windows
        self.createdAt = Date()
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

    func update(profileId: String, windows: [WindowSnapshot]) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        profiles[idx].windows = windows
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
