import Foundation

/// llama.cpp serves the local Qwen3 8B GGUF. The installed build (0.8.0-dev)
/// exposes /health for readiness and the OpenAI-compatible /v1 API; GPU
/// offload defaults to auto on Apple silicon.
public struct LlamaCppAdapter: ProviderAdapter {
    public init() {}
    public let id = ProviderID.llamacpp
    public let displayName = "llama.cpp"

    // MARK: Discovery

    public func models(profile: ProviderProfile) async -> [ModelChoice] {
        var choices: [ModelChoice] = []
        if profile.modelID.hasSuffix(".gguf"),
           FileManager.default.fileExists(atPath: profile.modelID) {
            choices.append(Self.choice(for: profile.modelID))
        }
        // Every GGUF in the model library, at any depth: drop a model
        // folder (or file) into ~/AI/models and it shows up here.
        for path in ModelLibrary.ggufFiles() where path != profile.modelID {
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
        return [
            SetupCheck(label: "llama-server", ok: fm.isExecutableFile(atPath: profile.executablePath),
                       detail: profile.executablePath),
            SetupCheck(label: "Model file",
                       ok: profile.modelID.hasSuffix(".gguf")
                            && fm.fileExists(atPath: profile.modelID),
                       detail: profile.modelID),
        ]
    }

    // MARK: Launch

    public func launchPlan(profile: ProviderProfile) throws -> LaunchPlan {
        let exe = URL(fileURLWithPath: profile.executablePath)
        guard FileManager.default.isExecutableFile(atPath: profile.executablePath) else {
            throw LaunchPlanError("llama-server not found at \(profile.executablePath).")
        }
        guard profile.modelID.hasSuffix(".gguf"),
              FileManager.default.fileExists(atPath: profile.modelID) else {
            throw LaunchPlanError("GGUF model not found at \(profile.modelID).")
        }
        let bad = ArgumentGuard.violations(profile.extraArgs, for: id)
        guard bad.isEmpty else { throw LaunchPlanError(ArgumentGuard.rejectionMessage(bad)) }
        var args = ["-m", profile.modelID,
                    "--host", "127.0.0.1",
                    "--port", String(profile.port)]
        // Structured runtime options, flags per this build's --help.
        if let ctx = profile.contextLength { args += ["-c", String(ctx)] }
        if let ngl = profile.gpuLayers { args += ["-ngl", String(ngl)] }
        if let threads = profile.threadCount { args += ["-t", String(threads)] }
        args += profile.extraArgs
        return LaunchPlan(
            execURL: exe,
            arguments: args,
            environment: baseLaunchEnvironment(),
            workingDirectory: URL(fileURLWithPath: NSHomeDirectory()),
            readinessTimeout: 240,
            testTimeout: 120)
    }

    // MARK: Endpoint

    public func probe(port: Int, profile: ProviderProfile) async -> ProbeResult {
        // /health answers as soon as the HTTP server is up; 503 still proves
        // it is a llama-server loading its model.
        let health = await LocalHTTP.shared.json(port: port, path: "/health", timeout: 4)
        var isLlama = false
        if case .success(let obj) = health, obj["status"] as? String != nil { isLlama = true }
        if case .failure(.status(let code, _)) = health, code == 503 { isLlama = true }
        if isLlama {
            var modelID: String?
            let models = await LocalHTTP.shared.json(port: port, path: "/v1/models", timeout: 3)
            if case .success(let obj) = models,
               let data = obj["data"] as? [[String: Any]] {
                modelID = data.first?["id"] as? String
            }
            guard modelID == profile.modelID else {
                let listeners = await Task.detached(priority: .utility) {
                    PortInspector.listeners(port: port)
                }.value
                return .foreign(listeners: listeners)
            }
            return .provider(modelID: modelID, detail: "Running externally",
                             brewService: false)
        }
        let listeners = await Task.detached(priority: .utility) {
            PortInspector.listeners(port: port)
        }.value
        return .foreign(listeners: listeners)
    }

    public func isReady(port: Int, profile: ProviderProfile) async -> Bool {
        let r = await LocalHTTP.shared.json(port: port, path: "/health", timeout: 4)
        if case .success(let obj) = r { return (obj["status"] as? String) == "ok" }
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
                                                body: body, timeout: 120)
        switch r {
        case .failure(.refused):
            return .failed("llama-server is not answering on port \(port).")
        case .failure(.timedOut):
            return .failed("The generation request timed out.")
        case .failure(.status(let code, let snippet)):
            return .failed("llama-server returned HTTP \(code): \(snippet ?? "")")
        case .failure(.transport(let m)):
            return .failed("llama-server request failed: \(m)")
        case .success(let obj):
            let choices = obj["choices"] as? [[String: Any]]
            let msg = choices?.first?["message"] as? [String: Any]
            let content = (msg?["content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let reasoning = (msg?["reasoning_content"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !content.isEmpty || !reasoning.isEmpty {
                return .passed(modelReported: obj["model"] as? String)
            }
            return .failed("The model returned an empty response.")
        }
    }

    public func apiURLs(port: Int, profile: ProviderProfile) -> [APIURLEntry] {
        [APIURLEntry(label: "OpenAI-compatible API (llama.cpp)",
                     url: "http://127.0.0.1:\(port)/v1")]
    }
}
