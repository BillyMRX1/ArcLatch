import Foundation

/// The seam over the system's service manager. ArcLatch must be able to answer
/// "is the agent I started still registered?" without ever touching a real
/// bootstrap in tests, so every registration question goes through this.
public protocol ServiceRegistrar: Sendable {
    /// The domain+label identities the query names, e.g.
    /// `gui/501/homebrew.mxcl.ollama`.
    var targets: [String] { get }
    func registration() async -> ServiceRegistration
}

extension ServiceRegistrar {
    /// Waits (bounded) for the identity to leave the bootstrap and reports
    /// what the manager finally said.
    public func waitUntilUnregistered(timeout: TimeInterval) async -> ServiceRegistration {
        let deadline = Date().addingTimeInterval(timeout)
        var last = await registration()
        while last.blocksShutdown, Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            last = await registration()
        }
        return last
    }
}

/// `launchctl print gui/<uid>/<label>` answers registration by the agent's
/// exact identity: no shell, no port probing, and no guessing from whether an
/// HTTP port happens to be open yet.
public struct LaunchctlRegistrar: ServiceRegistrar {
    public let labels: [String]
    public let toolPath: String

    public init(labels: [String] = OllamaAdapter.launchAgentLabels,
                toolPath: String = "/bin/launchctl") {
        self.labels = labels
        self.toolPath = toolPath
    }

    public var targets: [String] {
        let uid = getuid()
        return labels.map { "gui/\(uid)/\($0)" }
    }

    public func registration() async -> ServiceRegistration {
        await Task.detached(priority: .utility) {
            var sawUnknown = false
            for target in targets {
                let r = ToolRunner.run(toolPath, ["print", target], timeout: 6,
                                       environment: baseLaunchEnvironment())
                let state = Self.classify(status: r.status, output: r.stdout + r.stderr)
                switch state {
                case .notRegistered: continue          // try the next label
                case .unknown: sawUnknown = true        // cannot rule it out yet
                case .registered, .stopping: return state
                }
            }
            return sawUnknown ? .unknown : .notRegistered
        }.value
    }

    /// launchctl exits 0 and prints the agent for a registered label, and
    /// answers "Could not find service" for one that is not loaded. Anything
    /// else (permission refused, a killed query) is unverifiable, not absent.
    static func classify(status: Int32, output: String) -> ServiceRegistration {
        if output.contains("Could not find service") { return .notRegistered }
        if output.contains("Bad request") && !output.contains("state =") { return .notRegistered }
        if output.contains("state = stopping") { return .stopping }
        if output.contains("state =") || status == 0 { return .registered }
        return .unknown
    }
}

/// Ollama on this Mac runs as the Homebrew LaunchAgent service, registered
/// under Homebrew's own label (`homebrew.mxcl.ollama`; older Homebrew releases
/// used `sh.brew.ollama`). ArcLatch manages that service only on explicit
/// Start/Stop actions via brew, leaves a service it did not start running, and
/// uses the HTTP API for discovery, readiness, and a short model test.
///
/// Registration, not the port, decides whether a service ArcLatch started is
/// still its own to shut down: a service that is still starting has no
/// listening port and is still registered.
public struct OllamaAdapter: ProviderAdapter {
    public let id = ProviderID.ollama
    public let displayName = "Ollama"
    public let serviceManagedLaunch = true

    private static let brew = "/opt/homebrew/bin/brew"
    /// The brew *formula* name `brew services` takes.
    private static let serviceLabel = "ollama"
    /// The LaunchAgent identity Homebrew registers, newest label first.
    public static let launchAgentLabel = "homebrew.mxcl.ollama"
    public static let legacyLaunchAgentLabel = "sh.brew.ollama"
    public static let launchAgentLabels = [launchAgentLabel, legacyLaunchAgentLabel]
    /// Ollama's built-in default when the service sets no OLLAMA_HOST.
    public static let defaultServicePort = 11434

    /// Injectable for tests; defaults to the real LaunchAgent plist.
    private let plistPath: String
    /// Registration queries go through this shim, so tests never call launchctl.
    private let registrar: any ServiceRegistrar

    public init(plistPath: String? = nil, registrar: (any ServiceRegistrar)? = nil) {
        self.plistPath = plistPath ?? Self.installedLaunchAgentPlist()
        self.registrar = registrar ?? LaunchctlRegistrar()
    }

    /// The plist Homebrew actually keeps, whichever label this install uses.
    static func installedLaunchAgentPlist() -> String {
        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        let fm = FileManager.default
        for label in launchAgentLabels {
            let path = dir + "/" + label + ".plist"
            if fm.fileExists(atPath: path) { return path }
        }
        return dir + "/" + launchAgentLabel + ".plist"
    }

    public var managedServiceLabel: String { Self.launchAgentLabel }

    public func serviceRegistration() async -> ServiceRegistration {
        await registrar.registration()
    }

    // MARK: Discovery

    public func models(profile: ProviderProfile) async -> [ModelChoice] {
        guard let result = try? await LocalHTTP.shared
            .json(port: profile.port, path: "/api/tags", timeout: 4).get(),
              let list = result["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            var detail: String? = nil
            if let details = entry["details"] as? [String: Any] {
                let size = (entry["size"] as? Double).map {
                    String(format: "%.1f GB", $0 / 1_073_741_824.0)
                }
                let quant = details["quantization_level"] as? String
                detail = [quant, size].compactMap { $0 }.joined(separator: " · ")
            }
            return ModelChoice(id: name, label: name, detail: detail)
        }
    }

    public func setupChecks(profile: ProviderProfile) -> [SetupCheck] {
        let fm = FileManager.default
        let exeOK = fm.isExecutableFile(atPath: profile.executablePath)
        let brewOK = fm.isExecutableFile(atPath: Self.brew)
        let plist = plistPath
        // The LaunchAgent plist is informational only: `brew services stop`
        // removes it and `brew services start` recreates it. Never block a
        // start on its absence when brew is available.
        let plistInstalled = fm.fileExists(atPath: plist)
        return [
            SetupCheck(label: "Ollama binary", ok: exeOK, detail: profile.executablePath),
            SetupCheck(label: "Homebrew service control", ok: brewOK,
                       detail: brewOK ? "\(Self.brew) services" : "brew not found"),
            SetupCheck(label: "LaunchAgent", ok: brewOK,
                       detail: (plistInstalled ? "installed: \(plist)"
                                               : "will be created by brew services start")
                            + " · registered as \(Self.launchAgentLabel)"),
        ]
    }

    // MARK: Launch (brew service only)

    public func launchPlan(profile: ProviderProfile) throws -> LaunchPlan {
        throw LaunchPlanError(
            "Ollama is managed as a Homebrew service; Start runs brew services start.")
    }

    public func startService(port: Int) async -> ServiceResult {
        let env = baseLaunchEnvironment()
        let r = ToolRunner.run(Self.brew,
                               ["services", "start", Self.serviceLabel],
                               timeout: 40, environment: env)
        if r.status != 0 {
            let msg = (r.stderr + r.stdout)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(msg.isEmpty ? "brew services start failed" : msg)
        }
        return .ok
    }

    /// The port the Homebrew service actually uses: a valid OLLAMA_HOST
    /// port wins, otherwise Ollama's built-in default 11434. `brew services
    /// stop` removes the plist and `start` recreates it, so a missing plist
    /// is a normal state and still resolves to 11434 — the answer is never
    /// nil for a configured service, so a stale saved port (e.g. 8083) can
    /// never survive bootstrap.
    public func configuredServicePort(profile: ProviderProfile) -> Int? {
        guard let data = FileManager.default.contents(atPath: plistPath),
              let obj = try? PropertyListSerialization
                    .propertyList(from: data, format: nil) as? [String: Any] else {
            return Self.defaultServicePort
        }
        if let env = obj["EnvironmentVariables"] as? [String: Any],
           let host = env["OLLAMA_HOST"] as? String {
            let portString = host.lastIndex(of: ":").map {
                String(host[host.index(after: $0)...])
            } ?? host
            if let port = Int(portString), isValidPort(port) { return port }
        }
        return Self.defaultServicePort
    }

    public func stopService(port: Int) async -> ServiceResult {
        let env = baseLaunchEnvironment()
        let r = ToolRunner.run(Self.brew,
                               ["services", "stop", Self.serviceLabel],
                               timeout: 40, environment: env)
        if r.status != 0 {
            let msg = (r.stderr + r.stdout)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(msg.isEmpty ? "brew services stop failed" : msg)
        }
        // brew exiting 0 is not the proof. A service that was still starting
        // has no open port to check, so shutdown is confirmed against the
        // LaunchAgent identity itself: ownership is retained until that agent
        // is out of the bootstrap.
        let settled = await registrar.waitUntilUnregistered(timeout: 20)
        return Self.stopOutcome(brewSucceeded: true, registration: settled,
                                label: managedServiceLabel)
    }

    /// The ownership rule for a stop, kept apart from the brew call so it is
    /// testable without ever starting or stopping a real service: an
    /// unconfirmed stop is a failed stop.
    static func stopOutcome(brewSucceeded: Bool, registration: ServiceRegistration,
                            label: String) -> ServiceResult {
        guard brewSucceeded else {
            return .failed("brew services stop failed")
        }
        switch registration {
        case .notRegistered:
            return .ok
        case .unknown:
            return .failed("\(label): ArcLatch could not confirm the service is "
                + "unregistered (“brew services list” shows the truth). Ownership is "
                + "retained so Stop or a later quit can retry.")
        case .registered, .stopping:
            return .failed("\(label) is still "
                + "\(registration == .stopping ? "stopping" : "registered") after "
                + "brew services stop. Ownership is retained so Stop or a later quit "
                + "can retry.")
        }
    }

    // MARK: Endpoint

    public func probe(port: Int, profile: ProviderProfile) async -> ProbeResult {
        let version = await LocalHTTP.shared.json(port: port, path: "/api/version",
                                                  timeout: 4)
        guard case .success(let obj) = version, obj["version"] != nil else {
            let listeners = await Task.detached(priority: .utility) {
                PortInspector.listeners(port: port)
            }.value
            return .foreign(listeners: listeners)
        }
        // Recognize the Homebrew LaunchAgent service: an `ollama serve` whose
        // executable lives under Homebrew and was started by launchd (ppid 1),
        // or — when no listener could be named — the exact registered agent
        // identity. Registration is the authority for what is service-managed.
        let listeners = await Task.detached(priority: .utility) {
            PortInspector.listeners(port: port)
        }.value
        let listenerSaysService = listeners.contains { l in
            l.ppid == 1 && (l.path.hasPrefix("/opt/homebrew")
                            || l.path.hasPrefix("/usr/local"))
        }
        let registered = await registrar.registration()
        let brewService = listenerSaysService || (listeners.isEmpty && registered.blocksShutdown)
        let versionString = obj["version"] as? String
        return .provider(modelID: nil,
                         detail: brewService
                            ? "Homebrew service · v\(versionString ?? "?")"
                            : "Started outside ArcLatch · v\(versionString ?? "?")",
                         brewService: brewService)
    }

    public func isReady(port: Int, profile: ProviderProfile) async -> Bool {
        let r = await LocalHTTP.shared.json(port: port, path: "/api/version", timeout: 3)
        if case .success = r { return true }
        return false
    }

    // MARK: Test

    /// Short generation. keep_alive 0 unloads the model right after the
    /// response so the test does not extend the model's residency.
    public func test(port: Int, profile: ProviderProfile) async -> GenerationOutcome {
        let body: [String: Any] = [
            "model": profile.modelID,
            "prompt": "Reply with OK",
            "stream": false,
            "think": false,
            "keep_alive": 0,
            "options": ["num_predict": 8, "temperature": 0.0],
        ]
        let r = await LocalHTTP.shared.postJSON(port: port, path: "/api/generate",
                                                body: body, timeout: 120)
        switch r {
        case .failure(.refused):
            return .failed("Ollama is not answering on port \(port).")
        case .failure(.timedOut):
            return .failed("Generation timed out while loading \(profile.modelID).")
        case .failure(.status(let code, let snippet)):
            return .failed("Ollama returned HTTP \(code): \(snippet ?? "")")
        case .failure(.transport(let m)):
            return .failed("Ollama request failed: \(m)")
        case .success(let obj):
            let response = (obj["response"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let thinking = (obj["thinking"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !response.isEmpty || !thinking.isEmpty {
                return .passed(modelReported: obj["model"] as? String ?? profile.modelID)
            }
            let error = obj["error"] as? String
            return .failed(error ?? "Model returned no output.")
        }
    }

    public func apiURLs(port: Int, profile: ProviderProfile) -> [APIURLEntry] {
        [APIURLEntry(label: "Ollama API", url: "http://127.0.0.1:\(port)")]
    }
}
