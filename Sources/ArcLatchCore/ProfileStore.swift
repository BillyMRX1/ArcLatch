import Foundation

/// Versioned, atomic JSON profile storage in Application Support.
/// A corrupt or unreadable store is preserved on disk (never deleted); the
/// app falls back to defaults and marks providers as needing setup.
public actor ProfileStore {
    public struct Snapshot: Codable {
        public var version: Int
        public var profiles: [String: ProviderProfile]
        // Optional: stores written before the Settings screen must keep
        // loading unchanged.
        public var settings: AppSettings?
    }

    public struct LoadResult: Sendable {
        public var profiles: [ProviderID: ProviderProfile]
        public var storeWasInvalid: Bool
        public var invalidProviders: [ProviderID]
        public var settings: AppSettings?
    }

    public static let currentVersion = 1

    private let fileURL: URL
    public nonisolated let fileLocation: String

    public init(url: URL? = nil) {
        if let url {
            self.fileURL = url
            self.fileLocation = url.path
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
            let dir = base.appendingPathComponent("ArcLatch", isDirectory: true)
            self.fileURL = dir.appendingPathComponent("profiles.json")
            self.fileLocation = fileURL.path
        }
    }

    public func load() -> LoadResult {
        var profiles: [ProviderID: ProviderProfile] = [:]
        for id in ProviderID.allCases { profiles[id] = .defaults(for: id) }
        var storeWasInvalid = false
        var invalid: [ProviderID] = []
        var loadedSettings: AppSettings?

        guard let data = try? Data(contentsOf: fileURL) else {
            return LoadResult(profiles: profiles, storeWasInvalid: false,
                              invalidProviders: [], settings: nil)
        }
        do {
            let decoder = JSONDecoder()
            let snap = try decoder.decode(Snapshot.self, from: data)
            loadedSettings = snap.settings
            for id in ProviderID.allCases {
                if let p = snap.profiles[id.rawValue] {
                    profiles[id] = merged(defaults: .defaults(for: id), saved: p)
                } else {
                    invalid.append(id)
                }
            }
        } catch {
            storeWasInvalid = true
            invalid = ProviderID.allCases
        }
        return LoadResult(profiles: profiles, storeWasInvalid: storeWasInvalid,
                          invalidProviders: invalid, settings: loadedSettings)
    }

    /// Keep old saved fields valid while allowing new fields to default in.
    private func merged(defaults d: ProviderProfile, saved s: ProviderProfile) -> ProviderProfile {
        var out = s
        if out.port <= 0 || out.port > 65535 { out.port = d.port }
        return out
    }

    /// Merges the given profiles (and, when provided, app settings) into
    /// the stored snapshot; a partial save never drops other settings.
    public func save(_ profiles: [ProviderID: ProviderProfile],
                     settings: AppSettings? = nil) throws {
        var snap = Snapshot(version: Self.currentVersion, profiles: [:])
        if let data = try? Data(contentsOf: fileURL),
           let existing = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snap = existing
            snap.version = Self.currentVersion
        }
        for (id, p) in profiles { snap.profiles[id.rawValue] = p }
        if let settings { snap.settings = settings }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snap)

        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        // Atomic write: temp file in the same directory, then rename.
        let tmp = dir.appendingPathComponent("profiles.json.tmp-\(UUID().uuidString)")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: fileURL)
        }
    }
}
