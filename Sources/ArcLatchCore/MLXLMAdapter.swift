import Foundation

/// MLX-LM serves the Ripple MLX preset on port 8081 with the served model id
/// and port that the existing ccmlx setup expects. Ripple uses custom model
/// code (ricursive.py); the server's trust flag is only passed when the
/// profile has the explicit per-profile "Allow custom code" opt-in enabled.
public struct MLXLMAdapter: ProviderAdapter {
    public init() {}
    public let id = ProviderID.mlxlm
    public let displayName = "MLX-LM"

    // MARK: Discovery

    public func models(profile: ProviderProfile) async -> [ModelChoice] {
        var choices: [ModelChoice] = []
        // The current selection is offered only while it is actually an
        // MLX-serveable folder; a stray path (e.g. a home folder chosen by
        // mistake) must not appear in the picker — Needs setup shows why.
        if ModelLibrary.isMLXDir(profile.modelID, FileManager.default) {
            choices.append(MLXLMAdapter.choice(for: profile.modelID))
        }
        // Every MLX-serveable folder (config.json + safetensors) anywhere in
        // the model library — the LM Studio layout included. No per-folder
        // registration: drop the folder in the library and it is listed.
        for path in ModelLibrary.mlxModelDirs() where path != profile.modelID {
            choices.append(Self.choice(for: path))
        }
        return choices
    }

    static func choice(for path: String) -> ModelChoice {
        ModelChoice(id: path, label: (path as NSString).lastPathComponent,
                    detail: (path as NSString).deletingLastPathComponent)
    }

    public func setupChecks(profile: ProviderProfile) -> [SetupCheck] {
        let fm = FileManager.default
        let exeOK = fm.isExecutableFile(atPath: profile.executablePath)
        let dir = profile.modelID
        let configOK = fm.fileExists(atPath: dir + "/config.json")
        let weightsOK: Bool
        if let entries = try? fm.contentsOfDirectory(atPath: dir) {
            weightsOK = entries.contains { $0.hasSuffix(".safetensors") }
        } else {
            weightsOK = false
        }
        let customCodeNeeded = Self.looksLikeCustomCode(dir)
        var checks = [
            SetupCheck(label: "MLX-LM server", ok: exeOK, detail: profile.executablePath),
            SetupCheck(label: "Model folder", ok: configOK && weightsOK, detail: dir),
        ]
        if customCodeNeeded {
            checks.append(SetupCheck(
                label: "Custom model code allowed",
                ok: profile.customCodeActive,
                detail: profile.customCodeActive
                    ? "Allow custom code is on for this exact model"
                    : "This model needs custom code — enable “Allow custom code for this model”"))
        }
        if profile.modelID != profile.customCodeApprovedModel && profile.allowCustomCode {
            checks.append(SetupCheck(
                label: "Custom-code consent is stale",
                ok: false,
                detail: "Consent was granted for a different model; it was cleared. "
                      + "Re-enable it if you trust this model."))
        }
        return checks
    }

    /// True when the model folder ships Python the engine must import.
    public static func looksLikeCustomCode(_ modelDir: String) -> Bool {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: modelDir) else { return false }
        return entries.contains { $0.hasSuffix(".py") }
    }

    // MARK: Launch

    public func launchPlan(profile: ProviderProfile) throws -> LaunchPlan {
        let exe = URL(fileURLWithPath: profile.executablePath)
        guard FileManager.default.isExecutableFile(atPath: profile.executablePath) else {
            throw LaunchPlanError("MLX-LM server not found at \(profile.executablePath).")
        }
        let bad = ArgumentGuard.violations(profile.extraArgs, for: id)
        guard bad.isEmpty else { throw LaunchPlanError(ArgumentGuard.rejectionMessage(bad)) }
        let dir = profile.modelID
        guard FileManager.default.fileExists(atPath: dir + "/config.json") else {
            throw LaunchPlanError("No config.json in \(dir).")
        }
        // The trust flag is generated only while consent is active for this
        // exact model; a stale or unrelated opt-in never carries over.
        if Self.looksLikeCustomCode(dir) && !profile.customCodeActive {
            throw LaunchPlanError(
                "This model uses custom code. Enable “Allow custom code for this model” "
                + "under Advanced settings to pass the server's trust flag.")
        }
        var args = ["--model", dir, "--host", "127.0.0.1", "--port", String(profile.port)]
        if profile.customCodeActive { args.append("--trust-remote-code") }
        // Structured runtime options, flags per mlx_lm.server --help.
        if let maxTok = profile.maxTokens { args += ["--max-tokens", String(maxTok)] }
        if let temp = profile.temperature { args += ["--temp", String(format: "%g", temp)] }
        args += profile.extraArgs
        return LaunchPlan(
            execURL: exe,
            arguments: args,
            environment: baseLaunchEnvironment(),
            workingDirectory: URL(fileURLWithPath: NSHomeDirectory()),
            readinessTimeout: 600,
            testTimeout: 180)
    }

    // MARK: Endpoint

    public func probe(port: Int, profile: ProviderProfile) async -> ProbeResult {
        let models = await LocalHTTP.shared.json(port: port, path: "/v1/models", timeout: 4)
        guard case .success(let obj) = models,
              let data = obj["data"] as? [[String: Any]] else {
            let listeners = await Task.detached(priority: .utility) {
                PortInspector.listeners(port: port)
            }.value
            return .foreign(listeners: listeners)
        }
        let served = (data.first?["id"] as? String)
        // Only the expected served id counts as MLX-LM (Ollama also answers
        // /v1/models); anything else is a port conflict.
        guard served == profile.modelID else {
            let listeners = await Task.detached(priority: .utility) {
                PortInspector.listeners(port: port)
            }.value
            return .foreign(listeners: listeners)
        }
        return .provider(modelID: served, detail: "Running externally",
                         brewService: false)
    }

    public func isReady(port: Int, profile: ProviderProfile) async -> Bool {
        let r = await LocalHTTP.shared.json(port: port, path: "/v1/models", timeout: 4)
        if case .success = r { return true }
        return false
    }

    public func test(port: Int, profile: ProviderProfile) async -> GenerationOutcome {
        let body: [String: Any] = [
            "model": profile.modelID,
            "messages": [["role": "user", "content": "Reply with OK"]],
            "max_tokens": 8,
            "temperature": 0.0,
        ]
        let r = await LocalHTTP.shared.postJSON(port: port,
                                                path: "/v1/chat/completions",
                                                body: body, timeout: 180)
        switch r {
        case .failure(.refused):
            return .failed("MLX-LM is not answering on port \(port).")
        case .failure(.timedOut):
            return .failed("The generation request timed out.")
        case .failure(.status(let code, let snippet)):
            return .failed("MLX-LM returned HTTP \(code): \(snippet ?? "")")
        case .failure(.transport(let m)):
            return .failed("MLX-LM request failed: \(m)")
        case .success(let obj):
            let choices = obj["choices"] as? [[String: Any]]
            let msg = choices?.first?["message"] as? [String: Any]
            let content = (msg?["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !content.isEmpty {
                return .passed(modelReported: obj["model"] as? String)
            }
            return .failed("The model returned an empty response.")
        }
    }

    /// The model id ccmlx expects is exactly the model folder path.
    public func apiURLs(port: Int, profile: ProviderProfile) -> [APIURLEntry] {
        [APIURLEntry(label: "OpenAI-compatible API (MLX-LM)",
                     url: "http://127.0.0.1:\(port)/v1")]
    }
}
