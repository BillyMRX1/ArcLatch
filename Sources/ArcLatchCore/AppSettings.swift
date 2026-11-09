import Foundation

/// App-level settings persisted alongside the provider profiles. The model
/// library folder is intentionally not baked into the binary: the default
/// is derived from the current user's home on every machine, and Settings
/// can point it anywhere; a saved path that doesn't exist on this machine
/// falls back to the default at startup.
public struct AppSettings: Codable, Equatable, Sendable {
    public var modelsDirectory: String?

    public init(modelsDirectory: String? = nil) {
        self.modelsDirectory = modelsDirectory
    }
}
