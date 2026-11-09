import AppKit
import Combine
import ArcLatchCore

// MARK: - App state
//
// The window is an AppKit shell hosting the SwiftUI view tree. Observation
// uses Combine (@Published / objectWillChange) because this toolchain has no
// SwiftUI macro plugin; views take these objects as plain parameters and the
// bridge rebuilds the root view whenever anything changes.

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var controllers: [ProviderController] = []
    @Published var selected: ProviderID = .ollama
    @Published var storeNote: String?
    @Published var quitNote: String?
    @Published var settingsNote: String?
    @Published var advancedExpanded: Set<ProviderID> = []
    /// The active model library folder; empty means none chosen. What a user
    /// picked is persisted; what ArcLatch picked automatically is not, so a
    /// fresh profile keeps the automatic behavior.
    @Published var modelsDirectory: String = ModelLibrary.noRoot
    /// How the current folder was decided, so each case gets its own words
    /// and its own action rather than a generic "no models found".
    @Published private(set) var libraryOutcome: ModelLibrary.RootOutcome = .noFolderChosen
    /// Library-level message shown next to the folder controls (unreachable
    /// folder, no folder chosen, …).
    @Published var libraryNote: String?
    /// The answer to the most recent **Retry**, shown where the button was.
    @Published var retryNote: String?
    /// One walk at a time: repeated Rescan clicks queue a single rerun
    /// instead of stacking scans.
    @Published private(set) var isScanningLibrary = false
    private var rescanQueued = false
    private var libraryStored: String?

    let memory: MemoryStripModel
    let store = ProfileStore()
    let isFake: Bool
    private var bootstrapped = false
    private var subscriptions: [AnyCancellable] = []

    private init() {
        isFake = ProcessInfo.processInfo.environment["ARC_LATCH_FAKE"] == "1"
        memory = MemoryStripModel(fake: isFake)
        subscriptions.append(memory.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        })
    }

    func bootstrapIfNeeded() {
        guard !bootstrapped else { return }
        bootstrapped = true
        Task {
            let loaded = await store.load()
            if bootstrapDebug { trace("bootstrap: profiles loaded") }
            // The saved setting wins; with nothing saved, ArcLatch uses
            // ~/AI/models when it is readable — never the whole home folder.
            let outcome = ModelLibrary.resolveRoot(saved: loaded.settings?.modelsDirectory)
            modelsDirectory = ModelLibrary.currentRoot()
            libraryOutcome = outcome
            switch outcome {
            case .automatic:
                libraryStored = nil            // not the user's choice: do not persist it
            case let .chosen(path), let .legacyHome(path):
                libraryStored = path           // honor and keep persisting what they saved
            case let .unavailable(path):
                libraryStored = path
                libraryNote = "The saved model folder “\(path)” cannot be read right now. "
                    + "Mount it and press Retry, or choose another folder."
            case .noFolderChosen:
                libraryStored = nil
                modelsDirectory = ModelLibrary.noRoot
                libraryNote = "No model folder chosen yet — ArcLatch will not scan your whole "
                    + "home folder on its own. Choose one in Settings…, or use "
                    + "Choose Model Folder… in a provider's detail pane."
            }
            for id in ProviderID.allCases {
                let c = ProviderController(id: id,
                                           adapter: Self.makeAdapter(id, fake: isFake),
                                           profile: loaded.profiles[id] ?? .defaults(for: id),
                                           store: store)
                c.onProfileChange = { [weak self] in self?.saveProfiles() }
                subscriptions.append(c.objectWillChange.sink { [weak self] _ in
                    self?.objectWillChange.send()
                })
                controllers.append(c)
            }
            if loaded.storeWasInvalid {
                storeNote = "The saved settings file could not be read, so defaults "
                    + "are in use. Fix each provider under Advanced settings; your "
                    + "previous file was left untouched."
            } else if !loaded.invalidProviders.isEmpty {
                storeNote = "Some saved settings are missing and use defaults: "
                    + loaded.invalidProviders.map { $0.displayName }
                        .joined(separator: ", ") + "."
            }
            // Start every provider's bootstrap together, and let monitoring
            // begin immediately. Serialized startup meant one provider stuck
            // in a slow folder walk left the providers after it showing an
            // empty model list indefinitely.
            for c in controllers where !isFake {
                Task { await c.monitorEndpoint() }
            }
            await withTaskGroup(of: Void.self) { group in
                for c in controllers {
                    let id = c.id          // actor-isolated; read it out here
                    group.addTask {
                        if bootstrapDebug { trace("bootstrap: \(id) begin") }
                        await c.bootstrap()
                        if bootstrapDebug { trace("bootstrap: \(id) done") }
                    }
                }
            }
            if bootstrapDebug { trace("bootstrap: all providers done") }
        }
    }

    static func makeAdapter(_ id: ProviderID, fake: Bool) -> any ProviderAdapter {
        if fake {
            var script = FakeAdapter.Script()
            let d = ProviderProfile.defaults(for: id)
            switch id {
            case .ollama:
                script.readyDelay = 0.8
                script.modelChoices = [
                    ModelChoice(id: "qwen3:8b", label: "qwen3:8b", detail: "demo"),
                    ModelChoice(id: "gpt-oss:20b", label: "gpt-oss:20b", detail: "demo"),
                ]
            case .splash:
                script.readyDelay = 2.4
                script.modelChoices = [ModelChoice(id: d.modelID, label: "Qwen3.8-Flash-Next-GSQ-RCO-GGUF:IQ3_S", detail: "demo preset")]
            case .mlxlm:
                script.readyDelay = 1.6
                script.modelChoices = [ModelChoice(id: d.modelID, label: "Ripple-65B-Preview-MLX-4bit", detail: "demo")]
            case .llamacpp:
                script.modelChoices = [ModelChoice(id: d.modelID, label: "Qwen3-8B-Q4_K_M.gguf", detail: "demo")]
            }
            return FakeAdapter(id: id, script: script)
        }
        switch id {
        case .ollama: return OllamaAdapter()
        case .splash: return SplashAdapter()
        case .mlxlm: return MLXLMAdapter()
        case .llamacpp: return LlamaCppAdapter()
        }
    }

    func controller(_ id: ProviderID) -> ProviderController? {
        controllers.first { $0.id == id }
    }

    func saveProfiles() {
        Task {
            var map: [ProviderID: ProviderProfile] = [:]
            for c in controllers { map[c.id] = c.profile }
            let settings = AppSettings(modelsDirectory: libraryStored)
            do { try await store.save(map, settings: settings) }
            catch { storeNote = "Could not save settings: \(error.localizedDescription)" }
        }
    }

    /// Open the Settings window (footer button; menu item uses ⌘,).
    func openSettings() {
        SettingsWindowController.shared.show()
    }

    /// Point the library at a folder the user picked (Settings screen, or the
    /// detail pane when a provider has nothing to show). The choice is
    /// persisted — unlike the automatic pick, which stays the app's business.
    func setModelsDirectory(_ path: String) {
        guard ModelLibrary.isReadableDirectory(path) else {
            settingsNote = "That folder does not exist, or ArcLatch cannot read it."
            return
        }
        settingsNote = nil
        libraryNote = nil
        retryNote = nil
        modelsDirectory = path
        libraryStored = path
        libraryOutcome = path == ModelLibrary.legacyHomeRoot
            ? .legacyHome(path) : .chosen(path)
        ModelLibrary.setRoot(path)
        saveProfiles()
        storeNote = "Model library set to \(shortUserPath(path)); all providers rescanned."
        rescanLibrary()
    }

    /// The folder picker, reachable from Settings and from a provider whose
    /// model list is empty.
    @discardableResult
    func chooseModelsDirectory() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if !modelsDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: modelsDirectory)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        setModelsDirectory(url.path)
        return url.path
    }

    /// Re-check a saved folder that could not be read: an unmounted volume or
    /// sleeping disk should come back without the user having to re-pick it.
    func retryLibraryFolder() {
        let saved = modelsDirectory
        guard !saved.isEmpty else { return }
        if ModelLibrary.isReadableDirectory(saved) {
            libraryNote = nil
            retryNote = "Model folder “\(shortUserPath(saved))” is readable again; "
                + "its models are listed."
            libraryOutcome = saved == ModelLibrary.legacyHomeRoot
                ? .legacyHome(saved) : .chosen(saved)
            storeNote = nil
            rescanLibrary()
        } else {
            retryNote = "“\(saved)” still cannot be read. Wait for the disk to "
                + "mount, or choose another folder."
        }
    }

    /// One click from the whole home folder (or nothing chosen) to the
    /// dedicated model folder.
    func useRecommendedLibrary() {
        setModelsDirectory(ModelLibrary.recommendedRoot)
    }

    /// One walk for the whole app: forced (background refreshes keep using
    /// the cache), off the main thread, and never stacked — clicks during a
    /// running scan queue exactly one more. When it lands, every provider
    /// that lists library models refreshes from it.
    func rescanLibrary() {
        guard !isScanningLibrary else {
            rescanQueued = true
            return
        }
        isScanningLibrary = true
        Task {
            await Task.detached(priority: .utility) { ModelLibrary.refresh() }.value
            isScanningLibrary = false
            for c in controllers { await c.bootstrap() }
            if rescanQueued {
                rescanQueued = false
                rescanLibrary()
            }
        }
    }

    /// Anything ArcLatch started or is still bringing up blocks a clean
    /// quit: owned processes and started services, service starts still in
    /// flight (even after cancel), in-flight cleanup, and unsettled starts
    /// or stops. The controller's `requiresShutdown` is the single source
    /// of truth shared with the shutdown targets below — a cancelled-but-
    /// pending start must never slip between the gate and the shutdown.
    var anyServerArcLatchOwns: Bool {
        controllers.contains { $0.requiresShutdown }
    }

    /// Stops every server ArcLatch owns and waits for confirmed exit
    /// through the app's single quit decision path (QuitGate). Returns the
    /// display names of providers that failed to stop.
    func stopServersForQuit() async -> [String] {
        await QuitGate.shutdown(controllers: controllers).failures
    }

    @MainActor func confirmQuitWithRunningServers() -> Bool {
        let alert = NSAlert()
        alert.messageText = "ArcLatch servers are running"
        alert.informativeText = """
        ArcLatch started one or more model servers that are still running. \
        Stop them and quit, or cancel and keep them running.
        """
        alert.addButton(withTitle: "Stop servers and quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - RAM strip model

@MainActor
final class MemoryStripModel: ObservableObject {
    @Published var sample: RAMSample?
    @Published var pressure: PressureState = .unknown
    /// Free + purgeable pages, for the start-time fit line near Start.
    @Published var freeBytes: UInt64?

    private let sampler: any MemorySamplerProtocol
    private let freeSampler: any FreeMemorySampling
    private let pressureMonitor = PressureMonitor()
    private var task: Task<Void, Never>?
    private var windowVisible = true
    private var appActive = true

    init(fake: Bool) {
        sampler = fake ? FakeMemorySampler() : SystemMemorySampler()
        freeSampler = fake ? FakeFreeMemorySampling() : SystemFreeMemory()
        pressureMonitor.start { state in
            Task { @MainActor in self.pressure = state }
        }
    }

    /// Sampling pauses while the window is hidden and resumes immediately
    /// when it becomes visible again.
    func setWindowVisible(_ visible: Bool) {
        windowVisible = visible
        resyncSampling()
    }

    func setAppActive(_ active: Bool) {
        appActive = active
        resyncSampling()
    }

    private func resyncSampling() {
        if windowVisible {
            startSampling()
        } else {
            task?.cancel()
            task = nil
        }
    }

    private func startSampling() {
        guard task == nil else { return }
        sample = sampler.sample()   // immediate value on resume
        freeBytes = freeSampler.freeBytes()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
                if let sample = self?.sampler.sample() { self?.sample = sample }
                if let free = self?.freeSampler.freeBytes() { self?.freeBytes = free }
            }
        }
    }

    nonisolated deinit { pressureMonitor.stop() }
}

// MARK: - AppKit helpers

/// Display form for paths: home directory abbreviated to ~.
func shortUserPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

enum PathPicker {
    static func run(canFiles: Bool, canDirectories: Bool, startDir: String?,
                    prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = canFiles
        panel.canChooseDirectories = canDirectories
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        if let startDir {
            panel.directoryURL = URL(fileURLWithPath: startDir, isDirectory: true)
        } else {
            panel.directoryURL = URL(fileURLWithPath: ModelLibrary.currentRoot())
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

enum Clipboard {
    static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

// MARK: - Launch tracing (ARC_LATCH_DEBUG_SCAN=1)

// An app that starts up empty is indistinguishable from one that started
// fine, so bug reports need the sequence: which provider bootstrapped, and
// whether the model scan ran at all.
private let bootstrapDebug =
    ProcessInfo.processInfo.environment["ARC_LATCH_DEBUG_SCAN"] != nil

private func trace(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
