import Foundation

/// What `splash serve` has to be pointed at to start a prepared bundle from
/// files that are already on this Mac, with no Hub access.
///
/// `--model` is only the **ID reported by the API** once `--model-dir` is
/// present (`splash serve --help`); the files actually loaded come from
/// `--model-dir`, which must name the local GGUF file or the directory whose
/// root holds the (possibly split) GGUF target. `--mmproj` carries the vision
/// projector, and `--draft-model` only applies when the bundle was prepared
/// from a local DFlash2 draft directory — a bundle whose draft came from the
/// Hugging Face cache re-resolves it locally, so passing nothing reproduces
/// the installed preset exactly.
public struct SplashLocalRoute: Equatable, Sendable {
    /// `--model-dir`: local GGUF file or GGUF/MLX model directory.
    public var modelDir: String
    /// `--mmproj`: the bundle's vision projector, when it has one.
    public var mmproj: String?
    /// `--draft-model`: a local DFlash2 draft directory, when the bundle
    /// recorded one; nil means "the draft released for the family", which
    /// Splash takes from the local Hugging Face cache.
    public var draftDir: String?
    /// Reproduce a bundle prepared without vision even when a projector is nearby.
    public var languageOnly: Bool

    public init(modelDir: String, mmproj: String? = nil, draftDir: String? = nil,
                languageOnly: Bool = false) {
        self.modelDir = modelDir
        self.mmproj = mmproj
        self.draftDir = draftDir
        self.languageOnly = languageOnly
    }
}

/// Why a Splash bundle cannot be used as-is. Surfaced next to Start, so a
/// moved or deleted asset names the item instead of exiting 1 in the logs.
public enum SplashBundleProblem: Equatable, Sendable {
    /// No readable model.json in the bundle directory.
    case unreadable(dir: String)
    /// The manifest names an asset whose path no longer resolves
    /// (a deleted file or a broken symlink).
    case missingAsset(name: String, path: String)
    /// The bundle holds no target GGUF, no draft, or no tokenizer.
    case incomplete(kind: String)
    /// The bundle is intact but its local target folder or file is gone, so
    /// `--model-dir` has nothing to prepare.
    case targetGone(path: String)

    public var message: String {
        switch self {
        case .unreadable(let dir):
            return "no readable model.json in \(dir)"
        case .missingAsset(let name, let path):
            return "asset “\(name)” is missing: \(path)"
        case .incomplete(let kind):
            return "the bundle records no \(kind)"
        case .targetGone(let path):
            return "the model files it was built from are missing: \(path)"
        }
    }
}

/// Splash serves the installed Qwen3.8-Flash-Next preset. ArcLatch relaunches
/// it through the installed CLI with `--offline`, which starts Splash's own
/// resolved local bundle (target GGUF, DFlash2 draft, tokenizer) with no Hub
/// access and no weight downloads. The exact bundle for a model id is bound
/// durably in the profile once verified — through a live server's own files
/// when one is running, then persisted — so the preset works from a stopped
/// state. A binding is never trusted blindly: its manifest is revalidated
/// (target, draft, tokenizer, every path present) before each launch. If the
/// mapping is missing, stale, or ambiguous, the provider shows Needs setup
/// and the user picks model files instead. Nothing ever resolves a remote id.
///
/// Cold start detail: `--model OWNER/REPO[:VARIANT]` alone makes Splash
/// re-resolve that repository — under `--offline` it fails outright ("neither
/// this installation nor the Hub cache records a commit for the default
/// branch"). The preset route therefore always passes `--model-dir` at the
/// bundle's local GGUF target (plus `--mmproj` when the bundle has a vision
/// projector), and keeps `--model` purely as the API model id clients expect.
public struct SplashAdapter: ProviderAdapter {
    public let id = ProviderID.splash
    public let displayName = "Splash"

    /// Injectable so tests can point at a fixture; defaults to the real
    /// Splash support directory.
    private let supportDir: String
    public init(supportDir: String? = nil) {
        self.supportDir = supportDir
            ?? NSHomeDirectory() + "/Library/Application Support/Splash"
    }

    // MARK: Preset resolution (identity-bound, durable)

    /// The bundle for the requested model id.
    /// 1. Durable binding: the profile's saved preset, kept with the exact
    ///    model id it was validated for, revalidated against its manifest.
    /// 2. Live pin: a serve lock naming this exact id, held by a live
    ///    process whose open files identify exactly one .resolved bundle.
    ///    This only discovers bindings; it is never required to launch.
    public func resolvedBundle(modelID: String, profile: ProviderProfile)
        -> (dir: String, files: [String])? {
        if let saved = profile.splashPreset, saved.modelID == modelID,
           let bundle = Self.validatedBundle(dir: saved.dir) {
            return bundle
        }
        return livePinnedBundle(modelID: modelID)
    }

    /// The bundle **and** the local route that starts it: nil unless both the
    /// binding and the files behind it are usable, so a launch never reaches
    /// Splash with an argument it would refuse.
    public func resolvedPreset(modelID: String, profile: ProviderProfile)
        -> (dir: String, route: SplashLocalRoute)? {
        guard let bundle = resolvedBundle(modelID: modelID, profile: profile) else { return nil }
        guard let route = Self.localRoute(dir: bundle.dir) else { return nil }
        return (bundle.dir, route)
    }

    /// Why the preset route cannot start, phrased for display next to Start;
    /// nil when it can. Every branch names the item the user can act on.
    public func presetBlocker(modelID: String, profile: ProviderProfile) -> String? {
        if let bundle = resolvedBundle(modelID: modelID, profile: profile) {
            if let problem = Self.routeProblem(dir: bundle.dir) {
                return "Preset bundle \(bundle.dir): \(problem.message)"
            }
            return nil
        }
        if let saved = profile.splashPreset, saved.modelID == modelID {
            let problem = Self.bundleProblem(dir: saved.dir)
                ?? Self.routeProblem(dir: saved.dir)
            return "Saved preset bundle \(saved.dir): \(problem?.message ?? "unusable")"
        }
        return "No verified preset bundle for \(modelID): choose model files under "
            + "Advanced settings, or start Splash once so ArcLatch can record the bundle."
    }

    /// Records a live-pinned bundle into the profile so the next start works
    /// cold. Nil when the profile already has a valid binding.
    public func discoveredPresetBundle(profile: ProviderProfile) -> SplashPresetBundle? {
        if let saved = profile.splashPreset, saved.modelID == profile.modelID,
           Self.validatedBundle(dir: saved.dir) != nil {
            return nil
        }
        guard let pinned = livePinnedBundle(modelID: profile.modelID) else { return nil }
        return SplashPresetBundle(modelID: profile.modelID, dir: pinned.dir)
    }

    func livePinnedBundle(modelID: String) -> (dir: String, files: [String])? {
        guard let lock = serveLock(naming: modelID) else { return nil }
        let opened = Self.openPaths(of: lock.pid)
        // Primary pin: the server keeps files inside its own bundle directory
        // open (model.json, files under target/draft/tokenizer).
        let dirs = Self.resolvedDirs(fromOpenPaths: opened)
        if dirs.count == 1, let dir = dirs.first, let bundle = Self.validatedBundle(dir: dir) {
            return bundle
        }
        if dirs.count > 1 { return nil } // ambiguous mapping: refuse
        // Fallback pin: exactly one valid bundle whose manifest paths the
        // server has open (it may serve through the source paths directly).
        let resolvedBase = supportDir + "/models/.resolved"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: resolvedBase)
        else { return nil }
        var matches: [(dir: String, files: [String])] = []
        for name in names.sorted() {
            guard let bundle = Self.validatedBundle(dir: resolvedBase + "/" + name) else { continue }
            if bundle.files.contains(where: { opened.contains($0) }) { matches.append(bundle) }
        }
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    /// Lock file for a live or last-run serve on the given port.
    func serveLock(port: Int) -> (pid: Int32, model: String, port: Int)? {
        readLock(supportDir + "/runtime/serve-\(port).lock")
    }

    /// Any serve lock naming this exact model id whose process is still
    /// alive. Stale locks (crashes, reboots) are skipped — a dead pid pins
    /// nothing, and no lock at all must not block a saved-preset start.
    func serveLock(naming modelID: String) -> (pid: Int32, model: String, port: Int)? {
        let dir = supportDir + "/runtime"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return nil
        }
        for name in names.sorted() where name.hasPrefix("serve") && name.hasSuffix(".lock") {
            if let lock = readLock(dir + "/" + name),
               lock.model == modelID, Self.processIsAlive(lock.pid) {
                return lock
            }
        }
        return nil
    }

    private func readLock(_ path: String) -> (pid: Int32, model: String, port: Int)? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = obj["pid"] as? Int,
              let model = obj["model"] as? String,
              let p = obj["port"] as? Int else { return nil }
        return (Int32(pid), model, p)
    }

    static func processIsAlive(_ pid: Int32) -> Bool {
        // Signal 0 checks existence without disturbing the process.
        kill(pid, 0) == 0
    }

    /// File paths a pid currently has open (lsof -Fn output).
    static func openPaths(of pid: Int32) -> Set<String> {
        let r = ToolRunner.run("/usr/sbin/lsof", ["-p", String(pid), "-Fn"],
                               timeout: 15, environment: baseLaunchEnvironment())
        guard !r.stdout.isEmpty else { return [] }
        var paths = Set<String>()
        for line in r.stdout.split(separator: "\n") where line.hasPrefix("n") {
            paths.insert(String(line.dropFirst()))
        }
        return paths
    }

    /// The .resolved bundle directories referenced by a set of open paths.
    static func resolvedDirs(fromOpenPaths paths: Set<String>) -> [String] {
        let marker = "/models/.resolved/"
        var found = Set<String>()
        for full in paths {
            guard let range = full.range(of: marker) else { continue }
            let hash = full[range.upperBound...].prefix(while: { $0.isHexDigit })
            guard hash.count == 64 else { continue }
            found.insert(String(full[..<range.upperBound]) + String(hash))
        }
        return found.sorted()
    }

    /// The bundle's own manifest (Splash writes it beside the asset links).
    static func manifest(dir: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: dir + "/model.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    /// (assembly path, source path) pairs the manifest links.
    static func manifestFiles(_ manifest: [String: Any]) -> [(name: String, path: String)]? {
        guard let entries = manifest["files"] as? [String: Any] else { return nil }
        var out: [(name: String, path: String)] = []
        for (name, entry) in entries {
            guard let path = (entry as? [String: Any])?["path"] as? String else { return nil }
            out.append((name, path))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// What is wrong with a bundle, if anything: every manifest path must
    /// resolve (a broken symlink counts as missing), and the bundle must hold
    /// a target GGUF, a draft, and a tokenizer.
    static func bundleProblem(dir: String) -> SplashBundleProblem? {
        let fm = FileManager.default
        guard let manifest = manifest(dir: dir),
              let files = manifestFiles(manifest), !files.isEmpty else {
            return .unreadable(dir: dir)
        }
        var hasTarget = false, hasDraft = false, hasTokenizer = false
        for file in files {
            // A broken symlink or removed source makes the bundle unusable.
            guard fm.fileExists(atPath: file.path) else {
                return .missingAsset(name: file.name, path: file.path)
            }
            if file.name.hasPrefix("target/") && file.name.hasSuffix(".gguf") { hasTarget = true }
            if file.name.hasPrefix("draft/") { hasDraft = true }
            if file.name.hasPrefix("tokenizer/") { hasTokenizer = true }
        }
        if !hasTarget { return .incomplete(kind: "target GGUF") }
        if !hasDraft { return .incomplete(kind: "DFlash2 draft") }
        if !hasTokenizer { return .incomplete(kind: "tokenizer") }
        return nil
    }

    /// Validates the bundle's required assets from its own manifest: at least
    /// one target GGUF, a draft, a tokenizer, and every manifest path present.
    static func validatedBundle(dir: String) -> (dir: String, files: [String])? {
        guard bundleProblem(dir: dir) == nil,
              let manifest = manifest(dir: dir),
              let files = manifestFiles(manifest) else { return nil }
        return (dir, files.map { $0.path })
    }

    /// Why `--model-dir` has nothing to prepare, when the bundle is otherwise
    /// intact (its local target folder or file moved away).
    static func routeProblem(dir: String) -> SplashBundleProblem? {
        guard let manifest = manifest(dir: dir) else { return .unreadable(dir: dir) }
        if localRoute(dir: dir, manifest: manifest) != nil { return nil }
        return .targetGone(path: recordedTarget(manifest) ?? dir)
    }

    /// The target path the bundle was prepared from, as Splash recorded it.
    static func recordedTarget(_ manifest: [String: Any]) -> String? {
        if let model = manifest["model"] as? String, !model.isEmpty { return model }
        if let sources = manifest["sources"] as? [String: Any],
           let target = sources["target"] as? [String: Any],
           let repo = target["repo"] as? String, repo.hasPrefix("/") { return repo }
        return nil
    }

    /// The `--model-dir` / `--mmproj` / `--draft-model` triple that prepares
    /// this bundle again from the files it links — no Hub, no download.
    static func localRoute(dir: String) -> SplashLocalRoute? {
        guard let manifest = manifest(dir: dir) else { return nil }
        return localRoute(dir: dir, manifest: manifest)
    }

    static func localRoute(dir: String, manifest: [String: Any]) -> SplashLocalRoute? {
        guard let files = manifestFiles(manifest) else { return nil }
        let fm = FileManager.default

        // Target: what the bundle records as its source, else the folder the
        // manifest's target GGUFs live in (one directory for every shard).
        var modelDir: String?
        if let recorded = recordedTarget(manifest), fm.fileExists(atPath: recorded) {
            modelDir = recorded
        } else {
            let shards = files
                .filter { $0.name.hasPrefix("target/") && $0.name.hasSuffix(".gguf") }
                .map { ($0.path as NSString).deletingLastPathComponent }
            if let first = shards.first, shards.allSatisfy({ $0 == first }),
               fm.fileExists(atPath: first) {
                modelDir = first
            }
        }
        guard let target = modelDir else { return nil }

        // Vision projector, when the bundle carries one: Splash needs the
        // file path, and preparing without it would drop the vision tower.
        let mmproj = files
            .first { $0.name.hasPrefix("vision/") && $0.name.hasSuffix(".gguf") }?
                .path

        // Draft: only when the bundle was prepared from a local draft
        // directory. A bundle whose draft came from the Hugging Face cache
        // records a repository id; Splash re-resolves that locally, and
        // inventing a path here would prepare a different bundle.
        var draftDir: String?
        if let sources = manifest["sources"] as? [String: Any],
           let draft = sources["draft"] as? [String: Any],
           let repo = draft["repo"] as? String, repo.hasPrefix("/"),
           fm.fileExists(atPath: repo) {
            draftDir = repo
        }
        return SplashLocalRoute(modelDir: target, mmproj: mmproj, draftDir: draftDir,
                                languageOnly: mmproj == nil && manifest["vision_format"] as? String == "none")
    }

    // MARK: Installed-bundle registry (informational)

    /// What Splash's own registry currently holds: resolved bundles on disk,
    /// how many pass the asset validation, and how many distinct model
    /// source folders they were installed from (real paths, so a folder
    /// reached through a symlink counts once). This raw count can include
    /// multiple installations of the same assets.
    public func registrySummary(profile: ProviderProfile) -> String? {
        let base = supportDir + "/models/.resolved"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base)
        else { return nil }
        let fm = FileManager.default
        var total = 0, usable = 0
        var sources = Set<String>()
        for name in names.sorted() {
            let dir = base + "/" + name
            guard fm.fileExists(atPath: dir + "/model.json") else { continue }
            total += 1
            if Self.validatedBundle(dir: dir) != nil { usable += 1 }
            if let data = fm.contents(atPath: dir + "/model.json"),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let src = obj["model"] as? String {
                if let r = realpath(src, nil) {
                    sources.insert(String(cString: r))
                    free(r)
                } else {
                    sources.insert(src)
                }
            }
        }
        guard total > 0 else { return nil }
        var parts = ["\(total) installed bundle\(total == 1 ? "" : "s")"]
        if usable < total { parts.append("\(usable) usable") }
        if !sources.isEmpty {
            parts.append("\(sources.count) model source folder\(sources.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Discovery

    public func models(profile: ProviderProfile) async -> [ModelChoice] {
        let current = resolvedPreset(modelID: profile.modelID, profile: profile)?.dir
        let base = supportDir + "/models/.resolved"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        var dirs = names.sorted().map { base + "/" + $0 }
        if let current {
            // Keep the exact saved choice when another bundle links the same files.
            dirs.removeAll { $0 == current }
            dirs.insert(current, at: 0)
        }

        let currentTargets = current.flatMap { Self.manifest(dir: $0) }
            .flatMap(Self.manifestFiles).map(Self.targetPaths)
        var seen = Set<[String]>()
        var choices: [ModelChoice] = []
        for dir in dirs {
            guard Self.bundleProblem(dir: dir) == nil,
                  let manifest = Self.manifest(dir: dir),
                  let files = Self.manifestFiles(manifest),
                  let route = Self.localRoute(dir: dir, manifest: manifest),
                  let target = files.first(where: {
                      $0.name.hasPrefix("target/") && $0.name.hasSuffix(".gguf")
                  }) else { continue }
            let assets = files.map { $0.name + ":" + Self.canonicalPath($0.path) }
            guard seen.insert(assets).inserted else { continue }

            let stem = ((target.name as NSString).lastPathComponent as NSString).deletingPathExtension
                .replacingOccurrences(of: "-[0-9]{5}-of-[0-9]{5}$", with: "", options: .regularExpression)
            let variant = route.mmproj != nil ? "Vision" : "Text only"
            // A local bundle may omit a Hub ID. Its directory name is a stable
            // local ID. Alternate routes to the current weights keep the API ID.
            let bundleName = (dir as NSString).lastPathComponent
            let modelID = currentTargets == Self.targetPaths(files)
                ? profile.modelID : "local/\(stem)-\(bundleName.prefix(12))"
            choices.append(ModelChoice(id: dir, label: "\(stem) · \(variant)",
                                       splashPreset: SplashPresetBundle(modelID: modelID, dir: dir)))
        }

        let labelCounts = Dictionary(grouping: choices, by: \.label).mapValues(\.count)
        for index in choices.indices where labelCounts[choices[index].label, default: 0] > 1 {
            let suffix = (choices[index].id as NSString).lastPathComponent.prefix(8)
            choices[index].label += " (\(suffix))"
        }
        return choices
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func targetPaths(_ files: [(name: String, path: String)]) -> [String] {
        files.filter { $0.name.hasPrefix("target/") && $0.name.hasSuffix(".gguf") }
            .map { canonicalPath($0.path) }
            .sorted()
    }

    public func setupChecks(profile: ProviderProfile) -> [SetupCheck] {
        let fm = FileManager.default
        let exeOK = fm.isExecutableFile(atPath: profile.executablePath)
        var checks = [SetupCheck(label: "Splash binary", ok: exeOK,
                                 detail: profile.executablePath)]
        if let dir = profile.localModelDir {
            checks.append(SetupCheck(label: "Chosen model folder",
                                     ok: fm.fileExists(atPath: dir), detail: dir))
        } else if let blocker = presetBlocker(modelID: profile.modelID, profile: profile) {
            // Names the missing item, so the fix is visible next to Start
            // rather than only in a crash line under Recent logs.
            checks.append(SetupCheck(label: "Installed preset", ok: false, detail: blocker))
        } else {
            let bundle = resolvedPreset(modelID: profile.modelID, profile: profile)
            checks.append(SetupCheck(label: "Installed preset",
                                     ok: bundle != nil,
                                     detail: bundle.map {
                                         "local bundle \($0.dir) · files \($0.route.modelDir)"
                                     } ?? "Locate model files to continue"))
        }
        if let draft = profile.draftPath {
            checks.append(SetupCheck(label: "Draft folder",
                                     ok: fm.fileExists(atPath: draft), detail: draft))
        }
        return checks
    }

    // MARK: Launch

    public func launchPlan(profile: ProviderProfile) throws -> LaunchPlan {
        let exe = URL(fileURLWithPath: profile.executablePath)
        guard FileManager.default.isExecutableFile(atPath: profile.executablePath) else {
            throw LaunchPlanError("Splash executable not found at \(profile.executablePath).")
        }
        let bad = ArgumentGuard.violations(profile.extraArgs, for: id)
        guard bad.isEmpty else { throw LaunchPlanError(ArgumentGuard.rejectionMessage(bad)) }
        var args = ["serve"]
        if let dir = profile.localModelDir {
            // Files the user chose in the GUI: same local-only route.
            guard FileManager.default.fileExists(atPath: dir) else {
                throw LaunchPlanError("Chosen Splash model folder is missing: \(dir). "
                    + "Choose model files again under Advanced settings.")
            }
            args += ["--model", profile.modelID, "--model-dir", dir, "--offline",
                     "--host", "127.0.0.1"]
            if let draft = profile.draftPath { args += ["--draft-model", draft] }
        } else {
            // Reuse the exact working preset: the resolved bundle's local
            // target and vision projector, its preset options, and no network
            // access. Works cold from the durable binding — no server needs to
            // be running, and nothing resolves a remote repository.
            guard let bundle = resolvedPreset(modelID: profile.modelID, profile: profile) else {
                throw LaunchPlanError(
                    presetBlocker(modelID: profile.modelID, profile: profile)
                    ?? "The installed preset for \(profile.modelID) is unavailable. "
                    + "Choose model files in Advanced settings, or reinstall the preset.")
            }
            // `--model` with `--model-dir` is only the ID the API reports, so
            // clients that expect the model id on this port keep working; the
            // files come from the local bundle.
            args += ["--model", profile.modelID, "--model-dir", bundle.route.modelDir,
                     "--offline", "--host", "127.0.0.1"]
            if let mmproj = bundle.route.mmproj { args += ["--mmproj", mmproj] }
            if bundle.route.languageOnly { args += ["--language-only"] }
            if let draft = profile.draftPath ?? bundle.route.draftDir {
                args += ["--draft-model", draft]
            }
        }
        // Structured runtime options, flags per `splash serve --help`.
        if let ctx = profile.contextLength { args += ["--max-context", String(ctx)] }
        if let mem = profile.maxMemoryGB { args += ["--max-memory", "\(mem)G"] }
        args += ["--port", String(profile.port)]
        args += profile.extraArgs
        return LaunchPlan(
            execURL: exe,
            arguments: args,
            environment: baseLaunchEnvironment(),
            workingDirectory: URL(fileURLWithPath: NSHomeDirectory()),
            readinessTimeout: 420,
            testTimeout: 120)
    }

    // MARK: Endpoint

    public func probe(port: Int, profile: ProviderProfile) async -> ProbeResult {
        let health = await LocalHTTP.shared.json(port: port, path: "/health", timeout: 4)
        guard case .success(let h) = health, (h["status"] as? String) == "ok" else {
            let listeners = await Task.detached(priority: .utility) {
                PortInspector.listeners(port: port)
            }.value
            return .foreign(listeners: listeners)
        }
        var modelID: String?
        let models = await LocalHTTP.shared.json(port: port, path: "/v1/models", timeout: 4)
        if case .success(let obj) = models,
           let data = obj["data"] as? [[String: Any]],
           let first = data.first {
            modelID = first["id"] as? String
        }
        // Identity requires this exact model id; another server (llama.cpp,
        // Ollama) answering the same shapes must read as a port conflict.
        guard modelID == profile.modelID else {
            let listeners = await Task.detached(priority: .utility) {
                PortInspector.listeners(port: port)
            }.value
            return .foreign(listeners: listeners)
        }
        // A Splash server is always the same family of binary; check the
        // runtime lock for extra identity (pid + id) when present.
        let detail: String
        if let lock = serveLock(port: port), lock.port == port {
            detail = "Running externally · locked id \(lock.model.components(separatedBy: "/").last ?? "")"
        } else {
            detail = "Running externally"
        }
        return .provider(modelID: modelID, detail: detail, brewService: false)
    }

    public func isReady(port: Int, profile: ProviderProfile) async -> Bool {
        let r = await LocalHTTP.shared.json(port: port, path: "/ready", timeout: 4)
        if case .success(let obj) = r { return (obj["status"] as? String) == "ready" }
        return false
    }

    public func test(port: Int, profile: ProviderProfile) async -> GenerationOutcome {
        let body: [String: Any] = [
            "model": profile.modelID,
            "messages": [["role": "user", "content": "Reply with OK"]],
            "max_tokens": 16,
            "temperature": 0.0,
        ]
        let r = await LocalHTTP.shared.postJSON(port: port,
                                                path: "/v1/chat/completions",
                                                body: body, timeout: 120)
        switch r {
        case .failure(.refused):
            return .failed("Splash is not answering on port \(port).")
        case .failure(.timedOut):
            return .failed("The generation request timed out.")
        case .failure(.status(let code, let snippet)):
            return .failed("Splash returned HTTP \(code): \(snippet ?? "")")
        case .failure(.transport(let m)):
            return .failed("Splash request failed: \(m)")
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
        [APIURLEntry(label: "OpenAI-compatible API (Splash)",
                     url: "http://127.0.0.1:\(port)/v1")]
    }
}
