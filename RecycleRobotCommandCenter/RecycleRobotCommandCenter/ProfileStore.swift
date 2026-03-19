import Foundation

struct WindowSnapshot: Codable {
    let appName: String
    let bundleIdentifier: String?
    let windowTitle: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
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
