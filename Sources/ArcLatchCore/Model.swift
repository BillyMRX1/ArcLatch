import Foundation

// MARK: - Identity

public enum ProviderID: String, Codable, CaseIterable, Sendable, Hashable {
    case ollama
    case splash
    case mlxlm
    case llamacpp

    public var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        case .splash: return "Splash"
        case .mlxlm: return "MLX-LM"
        case .llamacpp: return "llama.cpp"
        }
    }
}

// MARK: - Persisted profile

public struct ProviderProfile: Codable, Equatable, Sendable {
    /// Local TCP port the server is expected to bind (loopback only).
    public var port: Int
    /// Absolute path to the engine executable.
    public var executablePath: String
    /// Provider-specific model identity: an Ollama tag, a Splash model id,
    /// an MLX model folder, or a llama.cpp GGUF path.
    public var modelID: String
    /// MLX-LM only: explicit per-profile opt-in to pass the trust flag.
    public var allowCustomCode: Bool
    /// MLX-LM only: the model path the opt-in was granted for. The trust flag
    /// is active only while this matches `modelID`; changing the model clears
    /// consent (enforced in ProviderController.updateProfile).
    public var customCodeApprovedModel: String?
    /// Splash only: local draft directory override (advanced).
    public var draftPath: String?
    /// Splash only: local model dir override (advanced, used with --model-dir).
    public var localModelDir: String?
    /// Splash only: the preset bundle ArcLatch verified for a specific model
    /// id. Durable so cold starts work without a live server; revalidated
    /// against the bundle manifest before every launch.
    public var splashPreset: SplashPresetBundle?

    // MARK: Structured runtime options (nil = engine default)
    // Each provider exposes only the knobs its server actually supports;
    // the adapter maps them to that engine's own flags (verified against
    // the installed builds' --help), so no engine sees another's syntax.

    /// llama.cpp `-c/--ctx-size`; Splash `--max-context`. Token count.
    public var contextLength: Int?
    /// llama.cpp `-ngl/--n-gpu-layers`: layers offloaded to the GPU.
    public var gpuLayers: Int?
    /// llama.cpp `-t/--threads`: CPU generation threads.
    public var threadCount: Int?
    /// Splash `--max-memory`: Metal memory budget, whole GB.
    public var maxMemoryGB: Int?
    /// MLX-LM `--max-tokens`: default completion cap per request.
    public var maxTokens: Int?
    /// MLX-LM `--temp`: default sampling temperature.
    public var temperature: Double?

    /// Extra arguments appended verbatim (advanced; filtered by ArgumentGuard).
    public var extraArgs: [String]

    public init(port: Int, executablePath: String, modelID: String,
                allowCustomCode: Bool = false,
                customCodeApprovedModel: String? = nil,
                draftPath: String? = nil,
                localModelDir: String? = nil,
                splashPreset: SplashPresetBundle? = nil,
                contextLength: Int? = nil,
                gpuLayers: Int? = nil,
                threadCount: Int? = nil,
                maxMemoryGB: Int? = nil,
                maxTokens: Int? = nil,
                temperature: Double? = nil,
                extraArgs: [String] = []) {
        self.port = port
        self.executablePath = executablePath
        self.modelID = modelID
        self.allowCustomCode = allowCustomCode
        self.customCodeApprovedModel = customCodeApprovedModel
        self.draftPath = draftPath
        self.localModelDir = localModelDir
        self.splashPreset = splashPreset
        self.contextLength = contextLength
        self.gpuLayers = gpuLayers
        self.threadCount = threadCount
        self.maxMemoryGB = maxMemoryGB
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.extraArgs = extraArgs
    }

    /// True only while consent is on AND was granted for this exact model.
    public var customCodeActive: Bool {
        allowCustomCode && customCodeApprovedModel == modelID
    }

    public static func defaults(for id: ProviderID) -> ProviderProfile {
        switch id {
        case .ollama:
            return ProviderProfile(port: 11434,
                                   executablePath: "/opt/homebrew/bin/ollama",
                                   modelID: "qwen3:8b")
        case .splash:
            return ProviderProfile(port: 8000,
                                   executablePath: "/opt/homebrew/bin/splash",
                                   modelID: "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:IQ3_S")
        case .mlxlm:
            return ProviderProfile(port: 8081,
                                   executablePath: NSHomeDirectory() +
                                       "/AI/venvs/mlx/bin/mlx_lm.server",
                                   modelID: NSHomeDirectory() +
                                       "/AI/models/lmstudio/frogggias/Ripple-65B-Preview-MLX-4bit",
                                   allowCustomCode: false)
        case .llamacpp:
            return ProviderProfile(port: 8082,
                                   executablePath: NSHomeDirectory() +
                                       "/AI/projects/llama.cpp/build/bin/llama-server",
                                   modelID: NSHomeDirectory() + "/AI/models/Qwen3-8B-Q4_K_M.gguf")
        }
    }
}

// The active model library path is user-settable and persisted; see
// ModelLibrary.currentRoot() and AppSettings.modelsDirectory. The default
// is always the current user's ~/AI/models, so nothing is baked to one Mac.

// MARK: - Splash preset binding

/// A Splash preset bundle directory whose assets ArcLatch validated for one
/// exact model id. Saved so the preset can start from a stopped state; the
/// manifest is revalidated at every use so stale entries fail closed.
public struct SplashPresetBundle: Codable, Equatable, Sendable {
    public var modelID: String
    public var dir: String
    public init(modelID: String, dir: String) {
        self.modelID = modelID
        self.dir = dir
    }
}

// MARK: - Model choices offered by an adapter

public struct ModelChoice: Equatable, Identifiable, Sendable {
    public var id: String       // picker identity (modelID for most providers)
    public var label: String    // short display text
    public var detail: String?  // path or note under the label
    public var splashPreset: SplashPresetBundle?

    public init(id: String, label: String, detail: String? = nil,
                splashPreset: SplashPresetBundle? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
        self.splashPreset = splashPreset
    }
}

// MARK: - Short display name

/// The name a result banner shows: short enough to read at a glance, with the
/// full path or model id kept elsewhere (the selectable path line, and the
/// logs). Providers name their models differently, so shortening is per
/// provider — a GGUF path loses its folder and extension, a Splash model id
/// loses its org, and an Ollama tag is already the short form.
public enum ModelDisplayName {
    public static func short(provider: ProviderID, profile: ProviderProfile,
                             reported: String? = nil) -> String {
        let raw = reported ?? profile.modelID
        switch provider {
        case .ollama:
            // "qwen3:8b" is the name users type; keep it whole.
            return raw
        case .splash:
            // "org/Model:VARIANT" → "Model:VARIANT".
            return raw.components(separatedBy: "/").last ?? raw
        case .llamacpp:
            // Drop the folder and the ".gguf" extension, nothing else: a name
            // like "Model.Q4_K_M.gguf" keeps its quant tag.
            let name = (raw as NSString).lastPathComponent
            return (name as NSString).pathExtension.lowercased() == "gguf"
                ? (name as NSString).deletingPathExtension
                : name
        case .mlxlm:
            return (raw as NSString).lastPathComponent
        }
    }
}

// MARK: - Setup checks

public struct SetupCheck: Equatable, Sendable {
    public var label: String
    public var ok: Bool
    public var detail: String?

    public init(label: String, ok: Bool, detail: String? = nil) {
        self.label = label
        self.ok = ok
        self.detail = detail
    }
}

// MARK: - Launch plan

public struct LaunchPlan: Equatable, Sendable {
    public var execURL: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL
    public var readinessTimeout: TimeInterval
    public var testTimeout: TimeInterval
    /// How long a process must survive to count as "launched" before the
    /// early-exit guard fires.
    public var earlyExitGrace: TimeInterval

    public init(execURL: URL, arguments: [String], environment: [String: String],
                workingDirectory: URL, readinessTimeout: TimeInterval,
                testTimeout: TimeInterval, earlyExitGrace: TimeInterval = 1.5) {
        self.execURL = execURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.readinessTimeout = readinessTimeout
        self.testTimeout = testTimeout
        self.earlyExitGrace = earlyExitGrace
    }
}

// MARK: - Endpoint probe results

public struct ProcessListener: Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var path: String
    public init(pid: Int32, ppid: Int32, path: String) {
        self.pid = pid
        self.ppid = ppid
        self.path = path
    }
    public var name: String { (path as NSString).lastPathComponent }
}

public enum ProbeResult: Equatable, Sendable {
    case closed
    /// The expected provider answers on this port. `brewService` marks the
    /// recognized Ollama Homebrew LaunchAgent service (stop is allowed via brew).
    case provider(modelID: String?, detail: String?, brewService: Bool)
    /// Something else holds the port.
    case foreign(listeners: [ProcessListener])
}

// MARK: - Generation test

public enum GenerationOutcome: Equatable, Sendable {
    case passed(modelReported: String?)
    case failed(String)
}

public struct LastTest: Equatable, Sendable {
    public var outcome: GenerationOutcome
    public var date: Date
    public init(outcome: GenerationOutcome, date: Date) {
        self.outcome = outcome
        self.date = date
    }
}

// MARK: - API URL copy targets

public struct APIURLEntry: Equatable, Sendable {
    public var label: String
    public var url: String
    public init(label: String, url: String) {
        self.label = label
        self.url = url
    }
}

// MARK: - Service control

public enum ServiceResult: Equatable, Sendable {
    case ok
    case failed(String)
}

/// What the system's service manager says about the agent a managed provider
/// runs under. A closed HTTP port does **not** answer this: a service start
/// that is still bringing its program up leaves the agent registered while it
/// listens nowhere, so "is this still ours to shut down?" is decided by the
/// agent's identity, never by probing the port.
public enum ServiceRegistration: Equatable, Sendable {
    /// Loaded, and its program is running or being launched.
    case registered
    /// Loaded, and its program is being torn down.
    case stopping
    /// Not loaded: nothing is left to stop.
    case notRegistered
    /// The manager could not be asked; treat as unverifiable, not as present.
    case unknown

    /// True while the agent is still in the bootstrap: shutdown is not done.
    public var blocksShutdown: Bool { self == .registered || self == .stopping }
}

// MARK: - Adapter protocol

public protocol ProviderAdapter: Sendable {
    var id: ProviderID { get }
    var displayName: String { get }

    /// Model choices for the picker. Async adapters may query a live server.
    func models(profile: ProviderProfile) async -> [ModelChoice]

    /// Read-only validation of executable, model files, and dependencies.
    func setupChecks(profile: ProviderProfile) -> [SetupCheck]

    /// Command, environment, and timeouts for a direct launch.
    /// Throws LaunchPlanError when direct launch does not apply.
    func launchPlan(profile: ProviderProfile) throws -> LaunchPlan

    /// True when the provider is started through a managed service
    /// (startService/stopService) instead of an ArcLatch-owned subprocess.
    var serviceManagedLaunch: Bool { get }
    func startService(port: Int) async -> ServiceResult
    func stopService(port: Int) async -> ServiceResult

    /// The port the managed service is actually configured to use, read from
    /// the service's own configuration. Nil when nothing verifiable exists.
    func configuredServicePort(profile: ProviderProfile) -> Int?

    /// The exact identity the managed service is registered under with the
    /// system's service manager (empty when the provider is not service-
    /// managed). Shutdown is confirmed against this, not against the port.
    var managedServiceLabel: String { get }

    /// What the service manager currently says about that identity.
    func serviceRegistration() async -> ServiceRegistration

    /// A durable preset binding discovered from live metadata that the
    /// profile does not yet carry (e.g. the bundle a live server pins).
    func discoveredPresetBundle(profile: ProviderProfile) -> SplashPresetBundle?

    /// Human-readable state of the provider's own model registry, for
    /// providers that serve from an internal store rather than loose files
    /// (Splash: installed bundles). Nil when there is nothing to report.
    func registrySummary(profile: ProviderProfile) -> String?

    /// Classify whatever holds the port.
    func probe(port: Int, profile: ProviderProfile) async -> ProbeResult

    /// True once the endpoint answers in the provider's ready form.
    func isReady(port: Int, profile: ProviderProfile) async -> Bool

    /// A short generation against the selected model.
    func test(port: Int, profile: ProviderProfile) async -> GenerationOutcome

    /// Copyable endpoints for this provider.
    func apiURLs(port: Int, profile: ProviderProfile) -> [APIURLEntry]
}

extension ProviderAdapter {
    public var serviceManagedLaunch: Bool { false }
    public func startService(port: Int) async -> ServiceResult {
        .failed("This provider is not managed as a service.")
    }
    public func stopService(port: Int) async -> ServiceResult {
        .failed("This provider is not managed as a service.")
    }
    public func configuredServicePort(profile: ProviderProfile) -> Int? { nil }
    public var managedServiceLabel: String { "" }
    public func serviceRegistration() async -> ServiceRegistration { .unknown }
    public func discoveredPresetBundle(profile: ProviderProfile) -> SplashPresetBundle? { nil }
    public func registrySummary(profile: ProviderProfile) -> String? { nil }
}

public struct LaunchPlanError: Error, CustomStringConvertible, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - Shared launch environment

/// A Finder launch does not inherit the interactive shell. Build a deliberate
/// minimal environment; aliases and startup files never enter the launch path.
public func baseLaunchEnvironment(extra: [String: String] = [:]) -> [String: String] {
    var env: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
        "HOME": NSHomeDirectory(),
        "USER": NSUserName(),
        "LOGNAME": NSUserName(),
        "TMPDIR": NSTemporaryDirectory(),
        "LANG": "en_US.UTF-8",
    ]
    for (k, v) in extra { env[k] = v }
    return env
}
