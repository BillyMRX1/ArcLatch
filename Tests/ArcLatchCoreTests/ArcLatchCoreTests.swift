import Testing
import Foundation
import Darwin
@testable import ArcLatchCore

// The suite is hermetic by default: fixtures live under /private/tmp, fake
// adapters and fake service registrators stand in for engines and for
// launchctl/brew, and the only real processes are the /bin/sleep and /bin/sh
// launch fixtures plus loopback listeners on high ports. Nothing here needs a
// running provider, an installed engine, a personal model folder, or another
// Mac's paths.
//
// Assertions that observe a **live** provider (a real Splash session pinning
// its own bundle through its lock file and open files) are opted in explicitly
// with `ARC_LATCH_LIVE=1 swift test`, so the default run never depends on —
// and never probes — someone else's running server.
let liveProviders = ProcessInfo.processInfo.environment["ARC_LATCH_LIVE"] == "1"

/// A fixture executable: `isExecutableFile` is all any launch plan checks
/// before it reaches its own arguments, and nothing runs it.
let fixtureExecutable = "/bin/sh"

// MARK: - Profile store

@Suite("Profile store")
struct ProfileStoreTests {
    private func makeDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arclatch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("round trip preserves provider settings")
    func roundTrip() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(url: dir.appendingPathComponent("profiles.json"))
        var result = await store.load()
        #expect(result.profiles[.llamacpp]?.port == 8082)

        result.profiles[.llamacpp]?.port = 9099
        result.profiles[.ollama]?.modelID = "gpt-oss:20b"
        try await store.save(result.profiles)

        let reloaded = await store.load()
        #expect(reloaded.profiles[.llamacpp]?.port == 9099)
        #expect(reloaded.profiles[.ollama]?.modelID == "gpt-oss:20b")
        #expect(!reloaded.storeWasInvalid)
        #expect(reloaded.profiles[.mlxlm]?.draftPath == nil)
    }

    @Test("corrupt store is preserved and defaults take over")
    func corruptStorePreserved() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("profiles.json")
        try "not json at all".data(using: .utf8)!.write(to: url)
        let store = ProfileStore(url: url)
        let loaded = await store.load()
        #expect(loaded.storeWasInvalid)
        #expect(loaded.profiles[.splash]?.port == 8000)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("atomic rewrite leaves a valid file")
    func atomicWrite() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(url: dir.appendingPathComponent("profiles.json"))
        for port in [8082, 8083, 8084] {
            var profiles = (await store.load()).profiles
            profiles[.llamacpp]?.port = port
            try await store.save(profiles)
        }
        let reloaded = await store.load()
        #expect(reloaded.profiles[.llamacpp]?.port == 8084)
    }
}

// MARK: - Port inspection

@Suite("Port inspection")
struct PortInspectorTests {
    @Test("closed port reports not listening")
    func closedPort() {
        #expect(!PortInspector.isListening(port: 59997, timeoutMS: 200))
    }

    @Test("open port is detected")
    func openPort() throws {
        let port: Int32 = 59998
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #expect(fd >= 0)
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 {
            close(fd)
            return // port unavailable; nothing to assert
        }
        listen(fd, 4)
        #expect(PortInspector.isListening(port: Int(port), timeoutMS: 400))
        close(fd)
    }
}

// MARK: - Coordinator lifecycle with a fake adapter

final class ServiceFake: ProviderAdapter, @unchecked Sendable {
    let id = ProviderID.ollama
    let displayName = "ServiceFake"
    let serviceManagedLaunch = true
    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    init() {}

    func models(profile: ProviderProfile) async -> [ModelChoice] {
        // Two models so list rendering and selection sync are exercised.
        [ModelChoice(id: "svc-a", label: "svc-a", detail: "fake"),
         ModelChoice(id: "svc-b", label: "svc-b", detail: "fake")]
    }
    func setupChecks(profile: ProviderProfile) -> [SetupCheck] {
        [SetupCheck(label: "engine", ok: true)]
    }
    func launchPlan(profile: ProviderProfile) throws -> LaunchPlan {
        throw LaunchPlanError("service only")
    }
    func startService(port: Int) async -> ServiceResult {
        startCalls += 1
        return .ok
    }
    func stopService(port: Int) async -> ServiceResult {
        stopCalls += 1
        return .ok
    }
    func probe(port: Int, profile: ProviderProfile) async -> ProbeResult {
        .provider(modelID: nil, detail: "service", brewService: true)
    }
    func isReady(port: Int, profile: ProviderProfile) async -> Bool { true }
    func test(port: Int, profile: ProviderProfile) async -> GenerationOutcome {
        .passed(modelReported: "svc")
    }
    func apiURLs(port: Int, profile: ProviderProfile) -> [APIURLEntry] { [] }
}

@MainActor
func poll(_ predicate: @MainActor () -> Bool, timeout: TimeInterval = 10) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return predicate()
}

@MainActor
func makeFakeController(script: FakeAdapter.Script) -> ProviderController {
    let adapter = FakeAdapter(id: .llamacpp, script: script)
    let profile = ProviderProfile(port: 59990, executablePath: "/bin/sleep",
                                  modelID: "fake-a")
    return ProviderController(id: .llamacpp, adapter: adapter, profile: profile)
}

@Suite("Coordinator lifecycle")
@MainActor
struct CoordinatorTests {
    @Test("start → ready → test → stop")
    func startReadyTestStop() async {
        var script = FakeAdapter.Script()
        script.readyDelay = 0.6
        let c = makeFakeController(script: script)

        c.start()
        #expect(c.status == .starting || c.status == .ready)
        let ready = await poll { c.status == .ready }
        #expect(ready, "expected ready, got \(c.status)")

        #expect(c.canTest)
        c.runTest()
        _ = await poll { c.lastTest != nil }
        if case .passed = c.lastTest?.outcome {} else {
            Issue.record("expected passed test, got \(String(describing: c.lastTest?.outcome))")
        }

        #expect(c.canStop)
        c.stop()
        let stopped = await poll { c.status == .stopped }
        #expect(stopped, "expected stopped, got \(c.status)")
        #expect(!c.isOwnedRunning)
    }

    @Test("launch failure is reported as needs-setup")
    func launchFailure() async {
        var script = FakeAdapter.Script()
        script.failsToLaunch = true
        script.launchLog = "model file unreadable"
        let c = makeFakeController(script: script)
        c.start()
        _ = await poll { c.busy == .none }
        guard case .needsSetup(let message) = c.status else {
            Issue.record("expected needsSetup, got \(c.status)")
            return
        }
        #expect(message.contains("unreadable"))
    }

    @Test("readiness timeout fails and cleans up the launch")
    func readyTimeout() async {
        var script = FakeAdapter.Script()
        script.failsToBecomeReady = true
        script.readinessTimeout = 1.5
        let c = makeFakeController(script: script)
        c.start()
        _ = await poll(timeout: 10) { c.status != .starting && c.busy == .none }
        guard case .failed = c.status else {
            Issue.record("expected failed, got \(c.status)")
            return
        }
        #expect(!c.isOwnedRunning, "launch must be cleaned up on timeout")
    }

    @Test("early process exit is reported as failed")
    func earlyExit() async {
        var script = FakeAdapter.Script()
        script.holdSeconds = 0.1
        let c = makeFakeController(script: script)
        c.start()
        let settled = await poll(timeout: 10) {
            if case .failed = c.status { return true }
            return false
        }
        #expect(settled, "expected early-exit failure, got \(c.status)")
    }

    @Test("cancel start stops the owned process")
    func cancelStart() async {
        var script = FakeAdapter.Script()
        script.readyDelay = 5
        let c = makeFakeController(script: script)
        c.start()
        #expect(c.status == .starting)
        c.cancelStart()
        #expect(c.status == .stopped)
        let settled = await poll(timeout: 10) { !c.isOwnedRunning }
        #expect(settled)
    }

    @Test("setup failure blocks start")
    func setupFailure() async {
        var script = FakeAdapter.Script()
        script.setupFails = true
        let c = makeFakeController(script: script)
        c.start()
        _ = await poll { c.busy == .none }
        guard case .needsSetup = c.status else {
            Issue.record("expected needsSetup, got \(c.status)")
            return
        }
    }

    @Test("cancel then restart reaches ready once")
    func cancelThenRestart() async {
        var script = FakeAdapter.Script()
        script.readyDelay = 1.0
        let c = makeFakeController(script: script)
        c.start()
        c.cancelStart()
        #expect(c.status == .stopped)
        c.start()
        let ready = await poll { c.status == .ready }
        #expect(ready, "second start should reach ready, got \(c.status)")
    }

    @Test("failed generation keeps server ready and records failure")
    func failedTestKeepsReady() async {
        var script = FakeAdapter.Script()
        script.readyDelay = 0.3
        script.testOutcome = .failed("endpoint mismatch")
        let c = makeFakeController(script: script)
        c.start()
        _ = await poll { c.status == .ready }
        c.runTest()
        _ = await poll { c.lastTest != nil }
        if case .failed(let message) = c.lastTest?.outcome {
            #expect(message == "endpoint mismatch")
        } else {
            Issue.record("expected failed test outcome")
        }
        #expect(c.status == .ready)
    }

    @Test("externally running service stops via service only")
    func externalServiceStop() async {
        // Put a real listener on the fake service's port so the port probe
        // proceeds to the adapter's endpoint probe.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(59991).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bound == 0, "test port 59991 must be free")
        listen(fd, 4)

        let adapter = ServiceFake()
        let profile = ProviderProfile(port: 59991, executablePath: "/bin/sleep",
                                      modelID: "svc")
        let c = ProviderController(id: .ollama, adapter: adapter, profile: profile)
        await c.bootstrap()
        guard case .runningExternally(_, let viaService) = c.status else {
            Issue.record("expected runningExternally, got \(c.status)")
            return
        }
        #expect(viaService)
        #expect(c.canStop)
        close(fd)   // service shutdown releases the port
        c.stop()
        _ = await poll { c.status == .stopped }
        #expect(c.status == .stopped, "service stop should finish stopped")
        #expect(adapter.stopCalls == 1)
    }
}

// MARK: - Crash/failure reason surfacing

@Suite("Crash reason surfacing")
@MainActor
struct CrashReasonTests {
    private func failedMessage(_ c: ProviderController) -> String? {
        if case .failed(let m) = c.status { return m }
        return nil
    }

    @Test("a nonzero-exit crash after ready surfaces the reason, not plain Stopped")
    func crashAfterReady() async {
        var script = FakeAdapter.Script()
        script.readyDelay = 0.3
        script.crashExitCode = 7
        script.crashDelay = 1.2
        let c = makeFakeController(script: script)
        c.start()
        let ready = await poll { c.status == .ready }
        #expect(ready, "expected ready before the fixture crashes, got \(c.status)")
        _ = await poll(timeout: 10) { failedMessage(c) != nil }
        let message = failedMessage(c)
        #expect(message != nil, "a crashing server must surface Failed, got \(c.status)")
        #expect(message?.contains("exit code 7") == true, "message was \(message ?? "nil")")
        #expect(message?.contains("Recent logs") == true,
                "the reason must point at the logs disclosure")
        #expect(c.detailStatusText.contains("exit code 7"),
                "the header line must show the reason, not a bare Stopped/Failed")
        #expect(c.status.sidebarText == "Failed")
        #expect(c.canStart, "a crashed provider stays restartable")
    }

    @Test("a signal death reports the signal and names the likely OOM cause")
    func signalDeath() async {
        var script = FakeAdapter.Script()
        script.readyDelay = 0.3
        script.crashBySignal = true
        script.crashDelay = 1.2
        let c = makeFakeController(script: script)
        c.start()
        let ready = await poll { c.status == .ready }
        #expect(ready, "expected ready before the fixture dies, got \(c.status)")
        _ = await poll(timeout: 10) { failedMessage(c) != nil }
        let message = failedMessage(c)
        #expect(message?.contains("killed by signal 9") == true, "message was \(message ?? "nil")")
        #expect(message?.contains("likely out of memory") == true)
    }

    @Test("a nonzero early exit during startup reports the crash code")
    func crashDuringStartup() async {
        var script = FakeAdapter.Script()
        script.readyDelay = 30          // never reaches ready
        script.crashExitCode = 5
        script.crashDelay = 0.4
        let c = makeFakeController(script: script)
        c.start()
        _ = await poll(timeout: 10) { failedMessage(c) != nil }
        let message = failedMessage(c)
        #expect(message?.contains("exit code 5") == true, "message was \(message ?? "nil")")
        #expect(!c.isOwnedRunning)
    }

    @Test("manual Stop stays clean: Stopped, never a failure reason")
    func manualStopStaysClean() async {
        var script = FakeAdapter.Script()
        script.readyDelay = 0.3
        script.holdSeconds = 120
        let c = makeFakeController(script: script)
        c.start()
        let ready = await poll { c.status == .ready }
        #expect(ready, "expected ready, got \(c.status)")
        c.stop()
        let settled = await poll(timeout: 20) {
            c.status == .stopped || c.status.isFailureLike
        }
        #expect(settled)
        #expect(c.status == .stopped,
                "a manual stop must land on Stopped, got \(c.status)")
        #expect(c.detailStatusText == "Stopped")
    }
}

// MARK: - RAM

@Suite("Memory monitor")
struct MemoryTests {
    @Test("system sampler produces a sane sample")
    func systemSampler() throws {
        let sampler = SystemMemorySampler()
        let sample = try #require(sampler.sample())
        let total = ProcessInfo.processInfo.physicalMemory
        #expect(sample.totalBytes == total)
        #expect(sample.usedBytes > 0)
        #expect(sample.usedBytes <= total)
        #expect(sample.fraction > 0.05)
    }

    @Test("fake sampler ramps")
    func fakeSampler() throws {
        let a = try #require(FakeMemorySampler(totalBytes: 64 * 1024 * 1024 * 1024).sample())
        let b = try #require(FakeMemorySampler(totalBytes: 64 * 1024 * 1024 * 1024,
                                               startTick: 3).sample())
        #expect(b.usedBytes > a.usedBytes)
    }

    @Test("formatting matches the strip design")
    func formatting() {
        // Readings at or above 10 GB display as whole numbers, like the mock.
        #expect(RAMFormat.gib(16 * 1073741824) == "16")
        #expect(RAMFormat.gib(UInt64(16.5 * 1073741824)) == "16")
        #expect(RAMFormat.gib(UInt64(8.2 * 1073741824)) == "8.2")
        #expect(RAMFormat.usedOverTotal(RAMSample(usedBytes: 16 * 1073741824,
                                                  totalBytes: 64 * 1073741824))
                == "16 / 64 GB")
    }
}

// MARK: - Adapter plans (flags verified against installed builds)

/// One disposable file under a fixture folder, returned path included.
func makeFixtureFile(_ path: String, _ contents: String = "x") throws -> String {
    let fm = FileManager.default
    try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                           withIntermediateDirectories: true)
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

@Suite("Adapter launch plans")
struct AdapterPlanTests {
    @Test("MLX plan enforces the custom-code opt-in, bound to the model")
    func mlxPlan() throws {
        // A Ripple-shaped fixture (config.json + weights + custom Python), so
        // the consent rules are exercised without another Mac's model folder.
        let root = "/private/tmp/arclatch-mlx-plan-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeFixtureFile(root + "/config.json", "{}")
        try makeFixtureFile(root + "/model.safetensors")
        try makeFixtureFile(root + "/ricursive.py", "# custom code the server must import")

        let adapter = MLXLMAdapter()
        let profile = ProviderProfile(port: 8081, executablePath: fixtureExecutable,
                                      modelID: root)
        #expect(throws: LaunchPlanError.self) {
            try adapter.launchPlan(profile: profile)
        }
        // Consent for a different model must not generate the trust flag.
        var stale = profile
        stale.allowCustomCode = true
        stale.customCodeApprovedModel = "/some/other/model"
        #expect(throws: LaunchPlanError.self) {
            try adapter.launchPlan(profile: stale)
        }
        var optedIn = profile
        optedIn.allowCustomCode = true
        optedIn.customCodeApprovedModel = profile.modelID
        let plan = try adapter.launchPlan(profile: optedIn)
        #expect(plan.arguments.contains("--trust-remote-code"))
        #expect(plan.arguments.contains("127.0.0.1"))
        #expect(plan.arguments.first == "--model")
        #expect(plan.arguments.contains(profile.modelID))
    }

    @Test("llama.cpp plan binds loopback with the GGUF")
    func llamaPlan() throws {
        let gguf = "/private/tmp/arclatch-llama-plan-\(UUID().uuidString)/Qwen3-8B-Q4_K_M.gguf"
        defer { try? FileManager.default.removeItem(atPath: (gguf as NSString).deletingLastPathComponent) }
        try makeFixtureFile(gguf)
        let adapter = LlamaCppAdapter()
        let plan = try adapter.launchPlan(profile: ProviderProfile(
            port: 8082, executablePath: fixtureExecutable, modelID: gguf))
        #expect(plan.arguments.contains("-m"))
        #expect(plan.arguments.contains("127.0.0.1"))
        #expect(plan.arguments.contains("8082"))
    }

    /// Live-only: it reads a real installed Splash preset. Off by default so
    /// the suite never depends on a provider being installed or running.
    @Test("(live) Splash plan relaunches the installed preset from local files",
          .enabled(if: liveProviders))
    func splashPlanLive() throws {
        let adapter = SplashAdapter()
        let profile = ProviderProfile.defaults(for: .splash)
        let checks = adapter.setupChecks(profile: profile)
        let presetCheck = checks.first { $0.label == "Installed preset" }
        #expect(presetCheck?.ok == true,
                "installed Splash preset must be discoverable: \(presetCheck?.detail ?? "")")
        let plan = try adapter.launchPlan(profile: profile)
        #expect(plan.arguments.contains("serve"))
        #expect(plan.arguments.contains("--offline"))
        #expect(plan.arguments.contains(profile.modelID))
        // The cold-start fix: the launch names local files, so Splash never
        // re-resolves the repository through the Hub.
        let dirIndex = try #require(plan.arguments.firstIndex(of: "--model-dir"))
        #expect(FileManager.default.fileExists(
            atPath: plan.arguments[dirIndex + 1]))
    }

    @Test("Ollama is service-managed, not a raw subprocess")
    func ollamaServiceManaged() {
        let adapter = OllamaAdapter()
        #expect(adapter.serviceManagedLaunch)
        #expect(throws: LaunchPlanError.self) {
            try adapter.launchPlan(profile: .defaults(for: .ollama))
        }
    }
}

// MARK: - Review regressions

/// Binds a disposable loopback listener and returns its fd, or nil when the
/// port is unavailable (test then skips its bound-port assumptions).
func bindListener(port: Int32) -> Int32? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { close(fd); return nil }
    listen(fd, 4)
    return fd
}

@Suite("Review fix 1: managed-service start, stop, cancel")
@MainActor
struct ManagedServiceTests {
    private func serviceController(readyDelay: Double,
                                   port: Int) -> (ProviderController, FakeAdapter) {
        var script = FakeAdapter.Script()
        script.serviceManaged = true
        script.readyDelay = readyDelay
        script.probeResult = .provider(modelID: nil, detail: "svc", brewService: true)
        let adapter = FakeAdapter(id: .ollama, script: script)
        let c = ProviderController(id: .ollama, adapter: adapter,
                                   profile: ProviderProfile(port: port,
                                                            executablePath: "/bin/sleep",
                                                            modelID: "svc"))
        return (c, adapter)
    }

    @Test("ArcLatch-started service is stoppable without an owned process")
    func startThenStop() async {
        let (c, adapter) = serviceController(readyDelay: 0.5, port: 59992)
        c.start()
        let ready = await poll { c.status == .ready }
        #expect(ready, "expected ready, got \(c.status)")
        #expect(!c.isOwnedRunning, "service start owns no subprocess")
        #expect(c.ownsManagedService)
        #expect(c.canStop, "Stop must be available after a successful service start")
        c.stop()
        let stopped = await poll(timeout: 20) { c.status == .stopped }
        #expect(stopped, "expected stopped, got \(c.status)")
        #expect(adapter.serviceStopCalls == 1)
        #expect(!c.ownsManagedService)
    }

    @Test("cancel after a service start stops the service that start requested")
    func cancelStopsStartedService() async {
        let (c, adapter) = serviceController(readyDelay: 5, port: 59994)
        c.start()
        _ = await poll { adapter.serviceStartCalls > 0 }
        c.cancelStart()
        #expect(c.status == .stopped)
        let cleaned = await poll(timeout: 15) {
            adapter.serviceStopCalls == 1 && !c.ownsManagedService
        }
        #expect(cleaned, "the cancelled start must clean up its own service start")
    }

    @Test("a pre-existing service is never recorded as ours; verifier cleanup leaves it")
    func preExistingServiceUntouched() async {
        guard let fd = bindListener(port: 59996) else { return }
        defer { close(fd) }
        let adapter = ServiceFake()
        let c = ProviderController(id: .ollama, adapter: adapter,
                                   profile: ProviderProfile(port: 59996,
                                                            executablePath: "/bin/sleep",
                                                            modelID: "svc"))
        await c.bootstrap()
        guard case .runningExternally = c.status else {
            Issue.record("expected runningExternally, got \(c.status)")
            return
        }
        #expect(!c.ownsManagedService, "external service must not be owned")
        #expect(adapter.startCalls == 0)
        // The verifier cleanup rule: stop only what was actually started.
        let verifierStarted = c.isOwnedRunning || c.ownsManagedService
        if verifierStarted { c.stop() }
        #expect(adapter.stopCalls == 0, "pre-existing service must not be stopped")
        if case .runningExternally = c.status {} else {
            Issue.record("service status must remain runningExternally")
        }
    }
}

@Suite("Review fix 2: quit waits for confirmed shutdown")
@MainActor
struct QuitShutdownTests {
    @Test("owned process is terminated and exit is confirmed")
    func ownedProcess() async {
        var script = FakeAdapter.Script()
        script.readyDelay = 0.3
        let c = makeFakeController(script: script)
        c.start()
        _ = await poll { c.status == .ready }
        let ok = await c.shutdownForQuit()
        #expect(ok, "clean owned shutdown must report success")
        #expect(!c.isOwnedRunning)
        let settled = await poll { c.status == .stopped }
        #expect(settled)
    }

    @Test("ArcLatch-started service is stopped on quit with identity recheck")
    func managedService() async {
        var script = FakeAdapter.Script()
        script.serviceManaged = true
        script.readyDelay = 0.3
        script.probeResult = .provider(modelID: nil, detail: "svc", brewService: true)
        let adapter = FakeAdapter(id: .ollama, script: script)
        let c = ProviderController(id: .ollama, adapter: adapter,
                                   profile: ProviderProfile(port: 59997,
                                                            executablePath: "/bin/sleep",
                                                            modelID: "svc"))
        c.start()
        _ = await poll { c.status == .ready }
        let ok = await c.shutdownForQuit()
        #expect(ok)
        #expect(adapter.serviceStopCalls == 1)
        #expect(!c.ownsManagedService)
    }
}

@Suite("Review fixes 3/6/7: consent binding, arg guards, port validation, test sync")
@MainActor
struct SelectionAndGuardTests {
    @Test("model change clears custom-code consent")
    func consentClearedOnModelChange() {
        let c = makeFakeController(script: FakeAdapter.Script())
        c.updateProfile { $0.allowCustomCode = true; $0.customCodeApprovedModel = "fake-a" }
        #expect(c.profile.customCodeActive)
        c.updateProfile { $0.modelID = "fake-b" }
        #expect(!c.profile.allowCustomCode)
        #expect(c.profile.customCodeApprovedModel == nil)
        #expect(!c.profile.customCodeActive)
    }

    @Test("invalid ports are never saved or usable")
    func invalidPort() async {
        let c = makeFakeController(script: FakeAdapter.Script()) // port 59990
        // Saving an out-of-range port is refused outright; the old value stands.
        c.updateProfile { $0.port = 0 }
        #expect(c.profile.port == 59990)
        #expect(c.portError != nil)
        c.updateProfile { $0.port = 70000 }
        #expect(c.profile.port == 59990)
        #expect(c.portError != nil)
        c.updateProfile { $0.port = 59995 }
        #expect(c.portError == nil)
        #expect(c.canStart)

        // Defense in depth: a controller created with a corrupt port must
        // refuse to start or probe, and report Needs setup.
        let broken = ProviderController(id: .llamacpp,
                                        adapter: FakeAdapter(id: .llamacpp),
                                        profile: ProviderProfile(port: 0,
                                                                 executablePath: "/bin/sleep",
                                                                 modelID: "fake-a"))
        broken.start()
        if case .needsSetup(let m) = broken.status {
            #expect(m.contains("1 and 65535"))
        } else {
            Issue.record("expected needsSetup for invalid port, got \(broken.status)")
        }
        await broken.refreshEndpoint()
        if case .needsSetup = broken.status {} else {
            Issue.record("refreshEndpoint must refuse an invalid port")
        }
    }

    @Test("generation test runs against the launched profile, and model changes clear old results")
    func testUsesLaunchedProfile() async {
        var script = FakeAdapter.Script()
        script.readyDelay = 0.3
        let adapter = FakeAdapter(id: .llamacpp, script: script)
        let c = ProviderController(id: .llamacpp, adapter: adapter,
                                   profile: ProviderProfile(port: 59990,
                                                            executablePath: "/bin/sleep",
                                                            modelID: "fake-b"))
        c.start()
        let ready = await poll { c.status == .ready }
        #expect(ready)
        c.updateProfile { $0.modelID = "fake-a" }
        #expect(c.lastTest == nil, "model change must clear the previous test result")
        c.runTest()
        _ = await poll { c.lastTest != nil }
        #expect(adapter.lastTestProfile?.modelID == "fake-b",
                "test must target the model the running server actually launched")
        c.stop()
        _ = await poll { c.status == .stopped }
    }
}

@Suite("Review fix 3: extra arguments cannot override launch invariants")
struct ArgumentGuardTests {
    @Test("reserved flags are detected in bare and =value forms")
    func guardFlags() {
        #expect(ArgumentGuard.violations(["--port", "9090"], for: .llamacpp) == ["--port"])
        #expect(ArgumentGuard.violations(["--host=0.0.0.0"], for: .mlxlm) == ["--host=0.0.0.0"])
        #expect(ArgumentGuard.violations(["--no-offline"], for: .splash) == ["--no-offline"])
        #expect(ArgumentGuard.violations(["--model", "x"], for: .splash) == ["--model"])
        #expect(ArgumentGuard.violations(["--trust-remote-code"], for: .mlxlm)
                == ["--trust-remote-code"])
        // -ngl is a structured runtime option now; only --temp is free-form.
        #expect(ArgumentGuard.violations(["-ngl", "99", "--temp", "0.2"], for: .llamacpp) == ["-ngl"])
        #expect(ArgumentGuard.violations(["--max-context", "4096"], for: .splash) == ["--max-context"])
        #expect(ArgumentGuard.violations(["--max-tokens=512"], for: .mlxlm) == ["--max-tokens=512"])
        #expect(ArgumentGuard.violations(["--temp", "0.2", "-c", "4096"], for: .llamacpp) == ["-c"])
    }

    /// The message of the `LaunchPlanError` a plan throws (empty when it throws
    /// nothing). Rejection is proven by the guard's own wording, so a fixture
    /// executable and model can stand in for an installed engine.
    private func rejection(_ plan: () throws -> LaunchPlan) -> String {
        do { _ = try plan(); return "" }
        catch let error as LaunchPlanError { return error.message }
        catch { return "unexpected error: \(error)" }
    }

    @Test("every engine adapter refuses override args at launch-plan time")
    func adaptersReject() throws {
        let root = "/private/tmp/arclatch-guard-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeFixtureFile(root + "/models/model.gguf")
        try makeFixtureFile(root + "/mlx/config.json", "{}")
        try makeFixtureFile(root + "/mlx/model.safetensors")

        var l = ProviderProfile(port: 8082, executablePath: fixtureExecutable,
                                modelID: root + "/models/model.gguf")
        l.extraArgs = ["--port", "9090"]
        let llama = rejection { try LlamaCppAdapter().launchPlan(profile: l) }
        #expect(llama.contains("Remove: --port"),
                "the guard, not a missing file, must be what refuses: \(llama)")

        var m = ProviderProfile(port: 8081, executablePath: fixtureExecutable,
                                modelID: root + "/mlx")
        m.allowCustomCode = true
        m.customCodeApprovedModel = m.modelID
        m.extraArgs = ["--trust-remote-code"]
        let mlx = rejection { try MLXLMAdapter().launchPlan(profile: m) }
        #expect(mlx.contains("Remove: --trust-remote-code"), "guard message: \(mlx)")

        var s = ProviderProfile(port: 8000, executablePath: fixtureExecutable,
                                modelID: "test/ModelX:Q8")
        s.extraArgs = ["--offline"]
        let splash = rejection { try SplashAdapter(supportDir: root).launchPlan(profile: s) }
        #expect(splash.contains("Remove: --offline"), "guard message: \(splash)")
    }
}

@Suite("Review fix 5: Splash preset mapping is identity-bound")
struct SplashIdentityTests {
    /// Live-only by design: it inspects a running Splash server's lock file
    /// and open files (`lsof`), which is the one assertion in this suite that
    /// watches someone else's process. Opt in with ARC_LATCH_LIVE=1.
    @Test("(live) server metadata pins the requested preset",
          .enabled(if: liveProviders))
    func bundleIdentity() {
        let adapter = SplashAdapter()
        let profile = ProviderProfile.defaults(for: .splash)
        // The live Splash session on this Mac pins the requested preset
        // through its lock file and open bundle files.
        #expect(adapter.resolvedBundle(modelID: profile.modelID, profile: profile) != nil,
                "the running Splash session must pin the requested preset")
        // An id with no verified mapping must NOT borrow any other bundle.
        var other = profile
        other.modelID = "someone-else/OtherModel:Q4"
        other.splashPreset = nil
        #expect(adapter.resolvedBundle(modelID: other.modelID, profile: other) == nil)
    }
}

// MARK: - Round 2: cold-start preset from durable metadata

@Suite("Round 2 fix 1: Splash cold-start preset (fixture)")
struct SplashPresetFixtureTests {
    private struct Fixture {
        let root: URL
        let bundleDir: String
        let srcDir: String
        let mmproj: String
        let shard1: String
        let draftDir: String
        let adapter: SplashAdapter
        var profile: ProviderProfile
    }

    /// A fixture shaped like a real Splash bundle: a 64-hex `.resolved`
    /// directory whose `model.json` links a **split** GGUF target, a draft, a
    /// tokenizer, and a vision projector — plus the `model` and `sources`
    /// records Splash writes when it prepares files that are already local.
    private func makeFixture(withPreset: Bool = true,
                             breakTarget: Bool = false,
                             recordedTargetGone: Bool = false,
                             splitShardFolders: Bool = false,
                             localDraftDir: Bool = false,
                             modelID: String = "test/ModelX:Q8") throws -> Fixture {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/arclatch-splash-fixture-\(UUID().uuidString)")
        // 64-hex bundle name, like Splash's own content-addressed dirs.
        let hash = String(repeating: "ab", count: 32)
        let bundle = root.appendingPathComponent("models/.resolved/\(hash)")
        let srcDir = root.appendingPathComponent("src/ModelX-Q8").path
        let otherDir = root.appendingPathComponent("src/elsewhere").path
        let mmproj = root.appendingPathComponent("src/mmproj-ModelX-BF16.gguf").path
        let draftDir = root.appendingPathComponent("draft-src").path
        let shard1 = srcDir + "/ModelX-Q8-00001-of-00002.gguf"
        let shard2 = (splitShardFolders ? otherDir : srcDir)
            + "/ModelX-Q8-00002-of-00002.gguf"
        func write(_ path: String, _ body: String = "asset") throws {
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try body.write(toFile: path, atomically: true, encoding: .utf8)
        }
        try write(shard1); try write(shard2); try write(mmproj)
        try write(draftDir + "/config.json", "{}")
        try write(draftDir + "/model.safetensors")
        let tok = root.appendingPathComponent("tok/tokenizer.json").path
        try write(tok)
        if breakTarget { try fm.removeItem(atPath: shard1) }
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        let recordedTarget = recordedTargetGone ? srcDir + "-missing" : srcDir
        let manifest: [String: Any] = [
            "model": recordedTarget,
            "family": "ModelX",
            "sources": [
                "target": ["repo": recordedTarget, "revision": NSNull()],
                // A Hub-cached draft is recorded as a repository id; a draft
                // directory on disk is recorded as that path.
                "draft": ["repo": localDraftDir ? draftDir : "someone/ModelX-DFlash2",
                          "revision": NSNull()],
            ],
            "files": [
                "target/ModelX-Q8-00001-of-00002.gguf": ["path": shard1],
                "target/ModelX-Q8-00002-of-00002.gguf": ["path": shard2],
                "draft/model.safetensors": ["path": draftDir + "/model.safetensors"],
                "tokenizer/tokenizer.json": ["path": tok],
                "vision/mmproj.gguf": ["path": mmproj],
            ],
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: bundle.appendingPathComponent("model.json"))
        try fm.createDirectory(at: root.appendingPathComponent("runtime"),
                               withIntermediateDirectories: true)
        var profile = ProviderProfile(port: 8010,
                                      executablePath: fixtureExecutable,
                                      modelID: modelID)
        if withPreset {
            profile.splashPreset = SplashPresetBundle(modelID: modelID, dir: bundle.path)
        }
        return Fixture(root: root, bundleDir: bundle.path, srcDir: srcDir, mmproj: mmproj,
                       shard1: shard1, draftDir: draftDir,
                       adapter: SplashAdapter(supportDir: root.path), profile: profile)
    }

    /// The message a refused launch plan shows beside Start.
    private func launchRefusal(_ f: Fixture) -> String {
        do { _ = try f.adapter.launchPlan(profile: f.profile); return "" }
        catch let error as LaunchPlanError { return error.message }
        catch { return "unexpected error: \(error)" }
    }

    @Test("a saved, valid binding starts cold from local files — no process, no serve lock")
    func coldStart() throws {
        let f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // Nothing is running: no lock files exist at all in the fixture.
        #expect(f.adapter.serveLock(naming: f.profile.modelID) == nil)
        let bundle = try #require(
            f.adapter.resolvedBundle(modelID: f.profile.modelID, profile: f.profile))
        #expect(bundle.dir == f.bundleDir)
        let check = f.adapter.setupChecks(profile: f.profile)
            .first { $0.label == "Installed preset" }
        #expect(check?.ok == true, "preset check failed: \(check?.detail ?? "")")

        let args = try f.adapter.launchPlan(profile: f.profile).arguments
        // The beta blocker: `--model OWNER/REPO:VARIANT` on its own makes
        // Splash re-resolve the repository, which `--offline` refuses outright.
        // The plan must name the bundle's local files instead.
        let dirIndex = try #require(args.firstIndex(of: "--model-dir"))
        #expect(args[dirIndex + 1] == f.srcDir,
                "--model-dir must name the bundle's own GGUF folder")
        #expect(FileManager.default.fileExists(atPath: args[dirIndex + 1]),
                "…and that path must exist before Start runs")
        #expect(args.contains("--offline"))
        #expect(args.contains("127.0.0.1"), "loopback stays explicit")
        // The vision projector comes from the bundle: preparing without it
        // would silently drop the vision tower.
        let mmprojIndex = try #require(args.firstIndex(of: "--mmproj"))
        #expect(args[mmprojIndex + 1] == f.mmproj)
        // A Hub-cached draft re-resolves from the local cache: passing a path
        // here would prepare a different bundle.
        #expect(!args.contains("--draft-model"))
        // API compatibility: `--model` with `--model-dir` is the id the server
        // reports, so clients that call the model id keep working.
        let modelIndex = try #require(args.firstIndex(of: "--model"))
        #expect(args[modelIndex + 1] == f.profile.modelID)
        #expect(args.first == "serve")
        #expect(args.last == "8010")
    }

    @Test("runtime options map to Splash's own flags alongside the local route")
    func presetKnobs() throws {
        var f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.profile.contextLength = 65_536
        f.profile.maxMemoryGB = 24
        let args = try f.adapter.launchPlan(profile: f.profile).arguments
        let ctxIndex = try #require(args.firstIndex(of: "--max-context"))
        #expect(args[ctxIndex + 1] == "65536")
        let memIndex = try #require(args.firstIndex(of: "--max-memory"))
        #expect(args[memIndex + 1] == "24G")
        #expect(args.contains("--model-dir"))
        #expect(args.contains("--offline"))
    }

    @Test("a bundle prepared from a local draft directory passes --draft-model")
    func localDraftRoute() throws {
        let f = try makeFixture(localDraftDir: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let args = try f.adapter.launchPlan(profile: f.profile).arguments
        let draftIndex = try #require(args.firstIndex(of: "--draft-model"))
        #expect(args[draftIndex + 1] == f.draftDir,
                "the draft directory the bundle recorded is the one that replays it")
    }

    @Test("a bundle whose local target moved away refuses and names it")
    func localTargetGone() throws {
        // The manifest still links intact shards, but they sit in two folders
        // and the recorded target path is gone: nothing is left to hand to
        // --model-dir.
        let f = try makeFixture(recordedTargetGone: true, splitShardFolders: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let check = f.adapter.setupChecks(profile: f.profile)
            .first { $0.label == "Installed preset" }
        #expect(check?.ok == false)
        let detail = try #require(check?.detail)
        #expect(detail.contains(f.srcDir + "-missing"),
                "the check must name the missing target: \(detail)")
        let message = launchRefusal(f)
        #expect(message.contains(f.srcDir + "-missing"),
                "Start must refuse and say what is missing: \(message)")
    }

    @Test("an unknown model id has no mapping — Needs setup, no launch")
    func unknownID() throws {
        var f = try makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.profile.modelID = "someone-else/OtherModel:Q4"
        #expect(f.adapter.resolvedBundle(modelID: f.profile.modelID,
                                         profile: f.profile) == nil)
        let check = f.adapter.setupChecks(profile: f.profile)
            .first { $0.label == "Installed preset" }
        #expect(check?.ok == false, "Needs setup must be shown when mapping is missing")
        #expect(throws: LaunchPlanError.self) { try f.adapter.launchPlan(profile: f.profile) }
    }

    @Test("a broken asset link invalidates even a saved binding, and names the item")
    func brokenAssetLink() throws {
        let f = try makeFixture(breakTarget: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(f.adapter.resolvedBundle(modelID: f.profile.modelID,
                                         profile: f.profile) == nil)
        let check = f.adapter.setupChecks(profile: f.profile)
            .first { $0.label == "Installed preset" }
        #expect(check?.ok == false)
        let detail = try #require(check?.detail)
        #expect(detail.contains("target/ModelX-Q8-00001-of-00002.gguf"),
                "the setup check must name the missing asset: \(detail)")
        #expect(detail.contains(f.shard1),
                "…and the path the user has to fix: \(detail)")
        let message = launchRefusal(f)
        #expect(message.contains(f.shard1),
                "Start must refuse and repeat the missing item: \(message)")
        #expect(throws: LaunchPlanError.self) { try f.adapter.launchPlan(profile: f.profile) }
    }

    @Test("the user-chosen files route stays local-only and loopback")
    func chosenFilesRoute() throws {
        var f = try makeFixture(withPreset: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.profile.localModelDir = f.srcDir
        let args = try f.adapter.launchPlan(profile: f.profile).arguments
        let dirIndex = try #require(args.firstIndex(of: "--model-dir"))
        #expect(args[dirIndex + 1] == f.srcDir)
        #expect(args.contains("--offline"))
        #expect(args.contains("127.0.0.1"))

        // A chosen folder that has since moved away is refused, not launched.
        f.profile.localModelDir = f.srcDir + "-gone"
        let message = launchRefusal(f)
        #expect(message.contains(f.srcDir + "-gone"), "names the missing folder: \(message)")
    }

    @Test("the guard reserves every flag the local route sets")
    func localRouteFlagsAreReserved() {
        for flag in ["--model-dir", "--mmproj", "--draft-model", "--served-model-name",
                     "--announce-served-name", "--language-only", "--revision",
                     "--offline", "--host", "--port", "--model"] {
            #expect(ArgumentGuard.violations([flag, "x"], for: .splash) == [flag],
                    "\(flag) is ArcLatch's to set")
        }
    }

    @Test("registry summary counts bundles, flags unusable ones, dedupes symlinked sources")
    func registrySummary() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/private/tmp/splash-registry-\(UUID().uuidString)")
        let resolved = root.appendingPathComponent("models/.resolved")
        func bundle(_ hash: String, source: String?, valid: Bool) throws {
            let dir = resolved.appendingPathComponent(hash)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var files: [String: Any] = [:]
            if valid {
                for (name, file) in [("target/m.gguf", "src/t.gguf"),
                                     ("draft/d.safetensors", "src/d.safetensors"),
                                     ("tokenizer/tok.json", "src/tok.json")] {
                    let url = root.appendingPathComponent(file)
                    try fm.createDirectory(at: url.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try "asset".write(to: url, atomically: true, encoding: .utf8)
                    files[name] = ["path": url.path]
                }
            } else {
                files["target/missing.gguf"] = ["path": root.appendingPathComponent("src/gone.gguf").path]
            }
            var manifest: [String: Any] = ["files": files]
            if let source { manifest["model"] = source }
            try JSONSerialization.data(withJSONObject: manifest)
                .write(to: dir.appendingPathComponent("model.json"))
        }
        let srcA = root.appendingPathComponent("srcA").path
        try fm.createDirectory(atPath: srcA, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("srcA-link").path
        try fm.createSymbolicLink(atPath: alias, withDestinationPath: srcA)
        try bundle(String(repeating: "a", count: 64), source: srcA, valid: true)
        try bundle(String(repeating: "b", count: 64), source: alias, valid: true)
        try bundle(String(repeating: "c", count: 64), source: nil, valid: false)
        let adapter = SplashAdapter(supportDir: root.path)
        let summary = adapter.registrySummary(profile: .defaults(for: .splash))
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(summary?.contains("3 installed bundles") == true)
        #expect(summary?.contains("2 usable") == true)
        #expect(summary?.contains("1 model source folder") == true,
                "a source reached through a symlink counts once")
    }

    @Test("Splash picker deduplicates bundles and selects the exact offline route")
    @MainActor
    func picksInstalledRoute() async throws {
        let f = try makeFixture(localDraftDir: true)
        let fm = FileManager.default
        defer { try? fm.removeItem(at: f.root) }
        let original = URL(fileURLWithPath: f.bundleDir).appendingPathComponent("model.json")
        let base = original.deletingLastPathComponent().deletingLastPathComponent()
        let manifest = try #require(SplashAdapter.manifest(dir: f.bundleDir))
        func write(_ manifest: [String: Any], named name: String) throws -> String {
            let folder = base.appendingPathComponent(String(repeating: name, count: 64))
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: manifest)
                .write(to: folder.appendingPathComponent("model.json"))
            return folder.path
        }

        _ = try write(manifest, named: "a")
        var textOnly = manifest
        var files = try #require(manifest["files"] as? [String: Any])
        files.removeValue(forKey: "vision/mmproj.gguf")
        textOnly["files"] = files
        textOnly["vision_format"] = "none"
        let textDir = try write(textOnly, named: "b")
        files.removeValue(forKey: "tokenizer/tokenizer.json")
        textOnly["files"] = files
        _ = try write(textOnly, named: "c")

        let controller = ProviderController(id: .splash, adapter: f.adapter, profile: f.profile)
        controller.modelChoices = await f.adapter.models(profile: f.profile)
        #expect(controller.modelChoices.map(\.id) == [f.bundleDir, textDir])
        #expect(controller.modelChoices.map(\.label) == ["ModelX-Q8 · Vision", "ModelX-Q8 · Text only"])

        controller.updateProfile {
            $0.localModelDir = f.srcDir
            $0.draftPath = f.draftDir
        }
        controller.selectSplashPreset(textDir)
        #expect(controller.profile.modelID == f.profile.modelID)
        #expect(controller.profile.splashPreset?.dir == textDir)
        #expect(controller.profile.localModelDir == nil)
        #expect(controller.profile.draftPath == nil)

        let text = try f.adapter.launchPlan(profile: controller.profile).arguments
        #expect(text.contains("--language-only"))
        #expect(text.contains("--offline"))
        #expect(text.contains(f.draftDir))
        #expect(!text.contains("--mmproj"))

        controller.status = .ready
        controller.selectSplashPreset(f.bundleDir)
        #expect(controller.profile.splashPreset?.dir == textDir)

        controller.status = .stopped
        controller.selectSplashPreset(f.bundleDir)
        let vision = try f.adapter.launchPlan(profile: controller.profile).arguments
        #expect(vision.contains(f.mmproj))
        #expect(!vision.contains("--language-only"))
    }

    @Test("a live server's bundle is discovered once and persisted for cold starts")
    func discoveryPersists() async throws {
        // Fixture stands in for the live pin: write a lock naming the id,
        // held by this very test process (guaranteed alive), with bundle
        // paths among its open files is not controllable — instead assert
        // discovery returns nil when nothing is live and the profile has no
        // binding, then that a binding survives a ProfileStore round trip.
        let f = try makeFixture(withPreset: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(f.adapter.discoveredPresetBundle(profile: f.profile) == nil)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("arclatch-preset-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(url: dir.appendingPathComponent("profiles.json"))
        var profiles = (await store.load()).profiles
        var p = profiles[.splash] ?? .defaults(for: .splash)
        p.splashPreset = SplashPresetBundle(modelID: p.modelID, dir: f.bundleDir)
        profiles[.splash] = p
        try await store.save(profiles)
        let reloaded = (await store.load()).profiles[.splash]
        #expect(reloaded?.splashPreset?.dir == f.bundleDir)
        // And the reloaded profile resolves cold through that binding.
        let rp = try #require(reloaded)
        #expect(SplashAdapter(supportDir: f.root.path)
            .resolvedBundle(modelID: rp.modelID, profile: rp)?.dir == f.bundleDir)
    }
}

// MARK: - Round 2: quit during a suspended service start

@Suite("Round 2 fix 2: quit waits for pending service starts")
@MainActor
struct PendingStartQuitTests {
    @Test("quit settles a suspended start, stops the service it completed, refuses retries")
    func quitDuringSuspendedStart() async {
        var script = FakeAdapter.Script()
        script.serviceManaged = true
        script.serviceStartDelay = 0.8      // startService suspends past quit
        script.readyDelay = 30              // never reaches ready
        script.probeResult = .provider(modelID: nil, detail: "svc", brewService: true)
        let adapter = FakeAdapter(id: .ollama, script: script)
        let c = ProviderController(id: .ollama, adapter: adapter,
                                   profile: ProviderProfile(port: 59999,
                                                            executablePath: "/bin/sleep",
                                                            modelID: "svc"))
        c.start()
        let began = await poll { adapter.serviceStartCalls == 1 }
        #expect(began, "the fake service start should be in progress")
        #expect(c.status == .starting)

        let ok = await c.shutdownForQuit()
        #expect(ok, "quit must settle the pending start before approving")
        #expect(adapter.serviceStopCalls == 1,
                "the service completed after quit began must be stopped first")
        #expect(!c.ownsManagedService)

        // A retry cannot race the cleanup of the previous attempt.
        c.start()
        #expect(adapter.serviceStartCalls == 1, "starts are refused once quit began")
    }
}

// MARK: - Settings: model library folder

// .serialized: these tests legitimately mutate the process-wide scan root,
// so they must not overlap each other. No other suite touches the global.
@Suite("Settings: model library folder", .serialized)
struct ModelLibrarySettingsTests {
    private func storeURL() -> URL {
        URL(fileURLWithPath: "/private/tmp/arclatch-settings-\(UUID().uuidString)")
            .appendingPathComponent("profiles.json")
    }

    @Test("settings round-trip; legacy stores without settings still load")
    func settingsRoundTrip() async throws {
        let url = storeURL()   // one URL: storeURL() mints a fresh UUID each call
        defer { try? FileManager.default.removeItem(
            at: url.deletingLastPathComponent()) }   // the folder, not just the file
        let store = ProfileStore(url: url)
        var profiles: [ProviderID: ProviderProfile] = [:]
        for id in ProviderID.allCases { profiles[id] = .defaults(for: id) }
        profiles[.llamacpp]?.port = 9092
        try await store.save(profiles, settings: AppSettings(modelsDirectory: "/private/tmp"))

        let loaded = await store.load()
        #expect(loaded.settings?.modelsDirectory == "/private/tmp")
        #expect(loaded.profiles[.llamacpp]?.port == 9092)
        #expect(!loaded.storeWasInvalid)

        // Legacy shape: a snapshot with no settings key keeps loading.
        let legacy = ProfileStore.Snapshot(version: 1, profiles: loaded.profiles
            .reduce(into: [String: ProviderProfile]()) { $0[$1.key.rawValue] = $1.value },
                                           settings: nil)
        try JSONEncoder().encode(legacy)
            .write(to: url)
        let again = await store.load()
        #expect(again.settings == nil)
        #expect(again.profiles[.llamacpp]?.port == 9092)
        #expect(!again.storeWasInvalid)
    }

    @Test("a saved choice is honored; a folder that is gone stays visible")
    func rootResolution() throws {
        let previous = ModelLibrary.currentRoot()
        let fixture = "/private/tmp/arclatch-savedroot-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: fixture, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: fixture)
            ModelLibrary.setRoot(previous)
        }

        let ok = ModelLibrary.resolveRoot(saved: fixture)
        #expect(ok == .chosen(fixture))
        #expect(ModelLibrary.currentRoot() == fixture)

        // A saved folder that cannot be read stays selected: the UI has to be
        // able to name it and offer Retry, not swap in a different library.
        let gone = ModelLibrary.resolveRoot(saved: "/Volumes/definitely-not-mounted/models")
        #expect(gone == .unavailable("/Volumes/definitely-not-mounted/models"))
        #expect(ModelLibrary.currentRoot() == "/Volumes/definitely-not-mounted/models")

        // The value older builds saved even when the user chose nothing is
        // preserved, but named — that is what lets Settings offer the switch.
        let legacy = ModelLibrary.resolveRoot(saved: ModelLibrary.legacyHomeRoot)
        #expect(legacy == .legacyHome(ModelLibrary.legacyHomeRoot))
        #expect(ModelLibrary.currentRoot() == ModelLibrary.legacyHomeRoot)
    }

    @Test("with nothing saved, the dedicated folder is used automatically")
    func automaticRootIsTheDedicatedFolder() throws {
        let previous = ModelLibrary.currentRoot()
        let parent = "/private/tmp/arclatch-auto-\(UUID().uuidString)"
        let fixture = parent + "/models"
        try FileManager.default.createDirectory(atPath: fixture, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: parent)
            ModelLibrary.setRoot(previous)
        }
        // The candidate is a parameter, so the test never depends on what
        // happens to live in the test machine's home folder.
        let outcome = ModelLibrary.resolveRoot(saved: nil, autoCandidate: fixture)
        #expect(outcome == .automatic(fixture))
        #expect(ModelLibrary.currentRoot() == fixture)
        #expect(ModelLibrary.hasRoot())
    }

    @Test("with no dedicated folder, nothing is scanned and nothing is invented")
    func noAutoCandidateMeansNoRoot() {
        let previous = ModelLibrary.currentRoot()
        defer { ModelLibrary.setRoot(previous) }
        let missing = "/private/tmp/arclatch-absent-\(UUID().uuidString)"
        let outcome = ModelLibrary.resolveRoot(saved: nil, autoCandidate: missing)
        #expect(outcome == .noFolderChosen)
        #expect(ModelLibrary.currentRoot() == ModelLibrary.noRoot)
        #expect(!ModelLibrary.hasRoot())
        #expect(ModelLibrary.scan(force: true).isEmpty)
        #expect(!ModelLibrary.lastScanBlocked(),
                "no folder chosen is not the same as a folder that refused")
    }

    @Test("an unreadable dedicated folder is not picked automatically")
    func unreadableAutoCandidateIsSkipped() throws {
        let previous = ModelLibrary.currentRoot()
        let fixture = "/private/tmp/arclatch-unreadable-auto-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: fixture, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture)
            try? FileManager.default.removeItem(atPath: fixture)
            ModelLibrary.setRoot(previous)
        }
        #expect(ModelLibrary.isDirectory(fixture), "it exists — readability is the question")
        #expect(ModelLibrary.autoRoot(recommending: fixture) == nil)
        #expect(ModelLibrary.resolveRoot(saved: nil, autoCandidate: fixture) == .noFolderChosen)
    }

    @Test("Rescan after add and remove follows the active folder")
    func rescanFollowsAddAndRemove() throws {
        let previous = ModelLibrary.currentRoot()
        let fixture = "/private/tmp/arclatch-addremove-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: fixture + "/nested",
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: fixture + "/keep.gguf", contents: Data("x".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: fixture)
            ModelLibrary.setRoot(previous)
        }
        ModelLibrary.setRoot(fixture)
        #expect(ModelLibrary.ggufFiles().count == 1)

        // A model dropped in a subfolder is invisible until the forced walk.
        FileManager.default.createFile(atPath: fixture + "/nested/added.gguf",
                                       contents: Data("x".utf8))
        #expect(ModelLibrary.ggufFiles().count == 1, "the cached scan is still in play")
        _ = ModelLibrary.refresh()
        #expect(ModelLibrary.ggufFiles().count == 2, "Rescan walks the folder again")

        // And a model that is gone disappears from the list on Rescan.
        try FileManager.default.removeItem(atPath: fixture + "/nested/added.gguf")
        _ = ModelLibrary.refresh()
        #expect(ModelLibrary.ggufFiles().count == 1)
    }

    @Test("results from a folder that changed mid-scan never land")
    func staleScanResultsAreDropped() throws {
        let previous = ModelLibrary.currentRoot()
        let oldFolder = "/private/tmp/arclatch-stale-old-\(UUID().uuidString)"
        let newFolder = "/private/tmp/arclatch-stale-new-\(UUID().uuidString)"
        for folder in [oldFolder, newFolder] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: oldFolder + "/old.gguf", contents: Data("x".utf8))
        FileManager.default.createFile(atPath: newFolder + "/new.gguf", contents: Data("x".utf8))
        defer {
            ModelLibrary.walkHookForTesting = nil
            for folder in [oldFolder, newFolder] {
                try? FileManager.default.removeItem(atPath: folder)
            }
            ModelLibrary.setRoot(previous)
        }
        ModelLibrary.setRoot(oldFolder)
        // The user moves to another folder while the first walk is running.
        ModelLibrary.walkHookForTesting = { _ in ModelLibrary.setRoot(newFolder) }
        #expect(ModelLibrary.scan(force: true).isEmpty,
                "entries found in the previous folder must not be published")
        ModelLibrary.walkHookForTesting = nil
        #expect(ModelLibrary.ggufFiles() == [newFolder + "/new.gguf"])
    }

    @Test("the scan uses the active root by default")
    func scanFollowsActiveRoot() throws {
        let root = "/private/tmp/arclatch-activeroot-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/sub",
                                                withIntermediateDirectories: true)
        try "x".write(toFile: root + "/sub/model.gguf", atomically: true, encoding: .utf8)
        let previous = ModelLibrary.currentRoot()
        defer {
            try? FileManager.default.removeItem(atPath: root)
            ModelLibrary.setRoot(previous)
        }
        ModelLibrary.setRoot(root)
        #expect(ModelLibrary.ggufFiles().contains(root + "/sub/model.gguf"))
        ModelLibrary.setRoot(previous)
    }

    @Test("an unreadable library root is reported as blocked, not empty")
    func unreadableRootIsFlagged() throws {
        let root = "/private/tmp/arclatch-unreadable-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root)
            try? FileManager.default.removeItem(atPath: root)
            ModelLibrary.setRoot(ModelLibrary.defaultRoot)
        }
        let previous = ModelLibrary.currentRoot()
        ModelLibrary.setRoot(root)
        #expect(ModelLibrary.scan().isEmpty)
        #expect(!ModelLibrary.rootReadable(),
                "permission-denied must not masquerade as 'no models here'")
        // Restore with a root that provably exists: a sibling test may have
        // left the active root pointing at a fixture it already deleted, and
        // a missing path is not readable — that would be a passing assertion
        // about the wrong thing.
        ModelLibrary.setRoot("/private/tmp")
        _ = ModelLibrary.scan(force: true)
        #expect(ModelLibrary.rootReadable(), "a readable root clears the flag")
        ModelLibrary.setRoot(previous)
    }

    @Test("a folder the OS refuses inside the library reads as blocked, not empty")
    func deniedFolderInsideLibraryIsFlagged() throws {
        let root = "/private/tmp/arclatch-blocked-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/models",
                                                withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: root + "/models")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: root + "/models")
            try? FileManager.default.removeItem(atPath: root)
            ModelLibrary.setRoot(ModelLibrary.defaultRoot)
        }
        ModelLibrary.setRoot(root)
        #expect(ModelLibrary.scan().isEmpty)
        #expect(ModelLibrary.rootReadable(), "the top level lists fine — that is the trap")
        #expect(ModelLibrary.lastScanBlocked(),
                "a refused folder below the root must not read as 'nothing here'")
    }

    @Test("a scan that runs out of time says so instead of looking complete")
    func scanTimeBudgetReportsPartial() throws {
        let root = "/private/tmp/arclatch-partial-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/a",
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root + "/a/one.gguf", contents: Data("x".utf8))
        defer {
            try? FileManager.default.removeItem(atPath: root)
            ModelLibrary.setRoot(ModelLibrary.defaultRoot)
        }
        ModelLibrary.setRoot(root)
        _ = ModelLibrary.scan(force: true, timeBudget: -1)   // budget already spent
        #expect(ModelLibrary.lastScanPartial(), "a walk that stopped must admit it")
        _ = ModelLibrary.scan(force: true, timeBudget: 5)
        #expect(!ModelLibrary.lastScanPartial(), "a scan that finished must not be flagged")
    }

    @Test("application-managed bundles are never walked into")
    func mediaLibraryBundlesAreSkipped() throws {
        let root = "/private/tmp/arclatch-bundles-\(UUID().uuidString)"
        let fm = FileManager.default
        // A GGUF buried inside a Photos-style bundle: not a user-dropped
        // model, and on a real Mac opening that bundle blocked the scan in
        // the kernel forever, emptying every provider behind it.
        try fm.createDirectory(atPath: root + "/Photos Library.photoslibrary/models",
                               withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/Photos Library.photoslibrary/models/hidden.gguf",
                      contents: Data("x".utf8))
        try fm.createDirectory(atPath: root + "/Real models", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/Real models/keep.gguf", contents: Data("x".utf8))
        defer {
            try? fm.removeItem(atPath: root)
            ModelLibrary.setRoot(ModelLibrary.defaultRoot)
        }
        ModelLibrary.setRoot(root)
        let found = ModelLibrary.scan(force: true).map { $0.path }
        #expect(found.contains { $0.hasSuffix("keep.gguf") })
        #expect(!found.contains { $0.hasSuffix("hidden.gguf") },
                "a bundle store is not a model folder, and must never be opened")
    }

    @Test("the picker never offers a folder that is not an MLX model")
    func mlxPickerFiltersInvalidCurrent() async throws {
        // The current selection is a folder that exists but cannot be served
        // (exactly the home-folder accident). It must never reach the picker,
        // while a scanned MLX folder does — all inside a fixture root.
        let root = "/private/tmp/arclatch-mlxpicker-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try makeFixtureFile(root + "/mlx-good/config.json", "{}")
        try makeFixtureFile(root + "/mlx-good/weights.safetensors")
        try makeFixtureFile(root + "/plain-folder/notes.txt")

        let previous = ModelLibrary.currentRoot()
        defer { ModelLibrary.setRoot(previous) }
        ModelLibrary.setRoot(root)

        var profile = ProviderProfile(port: 8081, executablePath: fixtureExecutable,
                                      modelID: NSHomeDirectory())
        let choices = await MLXLMAdapter().models(profile: profile)
        #expect(!choices.contains { $0.id == NSHomeDirectory() },
                "a stray path in the profile must not appear in the picker")
        #expect(choices.contains { $0.id == root + "/mlx-good" })
        #expect(!choices.contains { $0.id == root + "/plain-folder" })
        #expect(choices.allSatisfy { ModelLibrary.isMLXModelFolder($0.id) })
    }

    // MARK: Rescan semantics

    @Test("Rescan forces a fresh walk: added and removed GGUFs show up")
    func rescanSeesGGUFChanges() throws {
        let root = "/private/tmp/arclatch-rescan-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let previous = ModelLibrary.currentRoot()
        defer { ModelLibrary.setRoot(previous) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        ModelLibrary.setRoot(root)

        _ = ModelLibrary.scan()                       // primes the cache: empty
        try makeFixtureFile(root + "/New.gguf")
        #expect(!ModelLibrary.ggufFiles().contains(root + "/New.gguf"),
                "background refreshes read the cache, so a cached list is stale by design")
        _ = ModelLibrary.refresh()
        #expect(ModelLibrary.ggufFiles().contains(root + "/New.gguf"),
                "an explicit Rescan must walk the disk again")

        try FileManager.default.removeItem(atPath: root + "/New.gguf")
        #expect(ModelLibrary.ggufFiles().contains(root + "/New.gguf"),
                "the cache also holds deleted models until Rescan")
        _ = ModelLibrary.refresh()
        #expect(!ModelLibrary.ggufFiles().contains(root + "/New.gguf"),
                "a removed model must disappear on Rescan")
    }

    @Test("Rescan forces a fresh walk: MLX folders appear and disappear")
    func rescanSeesMLXChanges() throws {
        let root = "/private/tmp/arclatch-rescan-mlx-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let previous = ModelLibrary.currentRoot()
        defer { ModelLibrary.setRoot(previous) }
        try makeFixtureFile(root + "/first/config.json", "{}")
        try makeFixtureFile(root + "/first/w.safetensors")
        ModelLibrary.setRoot(root)
        #expect(ModelLibrary.mlxModelDirs() == [root + "/first"])

        try makeFixtureFile(root + "/second/config.json", "{}")
        try makeFixtureFile(root + "/second/w.safetensors")
        #expect(ModelLibrary.mlxModelDirs() == [root + "/first"], "still cached")
        _ = ModelLibrary.refresh()
        #expect(ModelLibrary.mlxModelDirs() == [root + "/first", root + "/second"])

        try FileManager.default.removeItem(atPath: root + "/first")
        _ = ModelLibrary.refresh()
        #expect(ModelLibrary.mlxModelDirs() == [root + "/second"])
    }

    @Test("the provider's Rescan action re-lists models a background refresh would miss")
    @MainActor
    func controllerRescanRelistsModels() async throws {
        let root = "/private/tmp/arclatch-rescan-provider-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let previous = ModelLibrary.currentRoot()
        defer { ModelLibrary.setRoot(previous) }
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        ModelLibrary.setRoot(root)

        let c = ProviderController(id: .llamacpp, adapter: LlamaCppAdapter(),
                                   profile: ProviderProfile(port: 59971,
                                                            executablePath: fixtureExecutable,
                                                            modelID: root + "/none.gguf"))
        await c.bootstrap()
        #expect(c.modelChoices.isEmpty, "nothing in the library yet")

        try makeFixtureFile(root + "/Dropped.gguf")
        await c.reloadModels()          // background-style refresh: cache again
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(c.modelChoices.isEmpty, "a background refresh keeps using the cache")

        await c.rescan()                // what the Rescan button does
        #expect(c.modelChoices.contains { $0.id == root + "/Dropped.gguf" },
                "Rescan must list the model the user just dropped in")
    }

    @Test("a bare home folder root gets the dedicated-folder nudge; a set folder does not")
    func bareHomeDefaultNudge() {
        #expect(ModelLibrary.isBareHomeDefault(ModelLibrary.defaultRoot))
        #expect(!ModelLibrary.isBareHomeDefault("/private/tmp/dedicated-models"))
        #expect(ModelLibrary.defaultRoot == NSHomeDirectory(),
                "the default is the current user's home, never a baked-in path")
    }
}

// MARK: - Global model-library scan

@Suite("Model library scan")
struct ModelLibraryScanTests {
    private func fixture() throws -> String {
        // Explicitly under /private/tmp, per the review fixture rule.
        let root = "/private/tmp/arclatch-lib-\(UUID().uuidString)"
        let fm = FileManager.default
        func mk(_ path: String, _ contents: String = "x") throws {
            let full = root + "/" + path
            try fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try contents.write(toFile: full, atomically: true, encoding: .utf8)
        }
        try mk("Top.gguf")                                  // listed (root file)
        try mk("mmproj-Vision.gguf")                        // accessory: skipped
        try mk("strata/IQ3_S/model.gguf")                   // listed (nested)
        try mk("toolong/a/b/c/d/deep.gguf")                 // past the depth-5 limit
        try mk("mlx-at-root/config.json", "{}")             // MLX leaf at depth 1
        try mk("mlx-at-root/weights.safetensors")
        try mk("mlx-at-root/inner.gguf")                    // model folders are leaves
        try mk("orgA/orgB/mlx-deep/config.json", "{}")      // MLX leaf at depth 3
        try mk("orgA/orgB/mlx-deep/w.safetensors")
        try mk("orgA/orgB/orgC/mlx-deeper/config.json", "{}")  // MLX leaf at depth 4
        try mk("orgA/orgB/orgC/mlx-deeper/w.safetensors")
        try mk("Split/Big-00001-of-00003.gguf")             // first shard: listed
        try mk("Split/Big-00002-of-00003.gguf")             // later shards: deduped
        try mk("Split/Big-00003-of-00003.gguf")
        try mk("ollama/blobs/sha256-abc.gguf")              // provider store: skipped
        try mk("huggingface-hub/repo/config.json", "{}")    // cache: skipped even
        try mk("huggingface-hub/repo/w.safetensors")        // if shaped like MLX
        try mk("snapshots/mlx/config.json", "{}")
        try mk("snapshots/mlx/w.safetensors")
        try mk(".hidden/Secret.gguf")
        return root
    }

    @Test("user-dropped models are classified by format; stores and caches skipped")
    func scanClassifies() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let ggufs = ModelLibrary.ggufFiles(root: root)
        let mlxs = ModelLibrary.mlxModelDirs(root: root)
        #expect(ggufs.contains(root + "/Top.gguf"))
        #expect(ggufs.contains(root + "/strata/IQ3_S/model.gguf"),
                "GGUFs in subfolders are found")
        #expect(!ggufs.contains(root + "/toolong/a/b/c/d/deep.gguf"))
        #expect(!ggufs.contains(root + "/mmproj-Vision.gguf"), "projectors are not models")
        #expect(ggufs.contains(root + "/Split/Big-00001-of-00003.gguf"),
                "the first shard represents the split model")
        #expect(!ggufs.contains(root + "/Split/Big-00002-of-00003.gguf"),
                "continuation shards are deduped")
        #expect(!ggufs.contains(root + "/Split/Big-00003-of-00003.gguf"))
        #expect(!ggufs.contains(root + "/ollama/blobs/sha256-abc.gguf"))
        #expect(!ggufs.contains(root + "/.hidden/Secret.gguf"))
        #expect(!ggufs.contains(root + "/mlx-at-root/inner.gguf"),
                "a model folder is a leaf; its internals are not listed separately")
        #expect(mlxs.contains(root + "/mlx-at-root"))
        #expect(mlxs.contains(root + "/orgA/orgB/mlx-deep"))
        #expect(mlxs.contains(root + "/orgA/orgB/orgC/mlx-deeper"),
                "depth 5 lets a home default reach lmstudio-style layouts")
        #expect(!mlxs.contains(root + "/huggingface-hub/repo"), "hub caches are skipped")
        #expect(!mlxs.contains(root + "/snapshots/mlx"))
    }
}

// MARK: - Round 3: cancel → quit for managed services

@Suite("Round 3 fix 1: cancel then quit (managed service)")
@MainActor
struct CancelThenQuitTests {
    private func serviceFake(startDelay: TimeInterval, port: Int, stopFails: Bool = false)
        -> (ProviderController, FakeAdapter) {
        var script = FakeAdapter.Script()
        script.serviceManaged = true
        script.serviceStartDelay = startDelay
        script.readyDelay = 30                    // never reaches ready
        script.serviceStopFails = stopFails
        script.probeResult = .provider(modelID: nil, detail: "svc", brewService: true)
        let adapter = FakeAdapter(id: .ollama, script: script)
        let c = ProviderController(id: .ollama, adapter: adapter,
                                   profile: ProviderProfile(port: port,
                                                            executablePath: "/bin/sleep",
                                                            modelID: "svc"))
        return (c, adapter)
    }

    @Test("cancel then quit: the gate sees it, quit waits, the service stops exactly once")
    func cancelThenQuit() async {
        // Port below macOS's ephemeral range so a random socket cannot
        // occupy it mid-run and masquerade as an external service.
        let (c, adapter) = serviceFake(startDelay: 0.8, port: 47880)
        c.start()
        let began = await poll { adapter.serviceStartCalls == 1 }
        #expect(began, "the fake service start should be in progress")

        // Cancel clears the visible starting state while the fake Homebrew
        // operation is still suspended — the gap this fix closes.
        c.cancelStart()
        #expect(c.status == .stopped, "cancel clears the starting state")
        #expect(c.requiresShutdown,
                "a cancelled-but-pending start must still count as ArcLatch's")
        #expect(!c.canStart, "Start stays disabled until the cancel settles")

        // Request quit through the exact decision path the app uses
        // (QuitGate: the gate AppState checks, then the shutdowns it runs).
        let decision = await QuitGate.shutdown(controllers: [c])
        #expect(decision.shutdownRequested,
                "the quit gate must not miss a cancelled pending start")
        #expect(decision.failures.isEmpty,
                "quit must wait for the start to settle and the service to stop")
        #expect(adapter.serviceStartCalls == 1)
        #expect(adapter.serviceStopCalls == 1, "the service is stopped exactly once")
        #expect(!c.ownsManagedService)

        // No retry races the completed quit.
        c.start()
        #expect(adapter.serviceStartCalls == 1, "no new start after a settled quit")
    }

    @Test("cleanup failure: quit refused, ownership retained, controls usable")
    func failedCleanupKeepsOwnership() async {
        let (c, adapter) = serviceFake(startDelay: 0, port: 47881, stopFails: true)
        c.start()
        let owned = await poll { c.ownsManagedService }
        #expect(owned, "the service start should complete (port must be free)")

        let decision = await QuitGate.shutdown(controllers: [c])
        #expect(decision.failures == ["Ollama"],
                "an unstopped service must keep the app open")
        #expect(c.ownsManagedService, "ownership state is retained for a retry")
        #expect(c.requiresShutdown, "a later quit still targets this provider")
        #expect(c.canStop, "Stop is available to retry the cleanup manually")
        #expect(adapter.serviceStopCalls == 1)
    }
}

// MARK: - Round 2: Ollama resolved port

@Suite("Round 2 fix 3: Homebrew-managed port resolution")
@MainActor
struct OllamaPortTests {
    private func fixtureDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ollama-plist-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writePlist(dir: URL, env: [String: String]?) throws -> String {
        let path = dir.appendingPathComponent("sh.brew.ollama.plist").path
        var root: [String: Any] = ["Label": "sh.brew.ollama"]
        if let env { root["EnvironmentVariables"] = env }
        try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test("LaunchAgent without OLLAMA_HOST resolves to Ollama's default 11434")
    func defaultPort() throws {
        let adapter = OllamaAdapter(plistPath: try writePlist(dir: fixtureDir(),
                                                              env: ["PATH": "/opt/homebrew/bin"]))
        #expect(adapter.configuredServicePort(profile: .defaults(for: .ollama)) == 11434)
    }

    @Test("a valid configured port wins over the default")
    func configuredPort() throws {
        let adapter = OllamaAdapter(plistPath: try writePlist(
            dir: fixtureDir(), env: ["OLLAMA_HOST": "127.0.0.1:11435"]))
        #expect(adapter.configuredServicePort(profile: .defaults(for: .ollama)) == 11435)
    }

    @Test("a stale saved port override is ignored and cannot be re-edited")
    func staleOverride() async {
        var script = FakeAdapter.Script()
        script.serviceManaged = true
        script.readyDelay = 0.3
        script.probeResult = .provider(modelID: nil, detail: "svc", brewService: true)
        script.configuredPort = 59989
        let adapter = FakeAdapter(id: .ollama, script: script)
        let c = ProviderController(id: .ollama, adapter: adapter,
                                   profile: ProviderProfile(port: 8083,
                                                            executablePath: "/bin/sleep",
                                                            modelID: "svc"))
        await c.bootstrap()
        #expect(c.profile.port == 59989, "bootstrap must adopt the service's port")
        c.updateProfile { $0.port = 9000 }
        #expect(c.profile.port == 59989)
        #expect(c.portError != nil)
        // The resolved port is what everything uses:
        #expect(c.apiURLEntries.first?.url.contains("59989") == true)
    }

    @Test("a missing LaunchAgent plist still resolves 11434 over a stale saved 8083")
    func missingPlistAdoptsDefault() async {
        // `brew services stop` removes the plist; its absence is normal and
        // must not let a stale saved port survive.
        let missing = fixtureDir().appendingPathComponent("absent.plist").path
        let adapter = OllamaAdapter(plistPath: missing)
        #expect(adapter.configuredServicePort(profile: .defaults(for: .ollama)) == 11434,
                "no plist is still a configured service: Ollama's default applies")

        var saved = ProviderProfile.defaults(for: .ollama)
        saved.port = 8083 // a stale override an older version could have saved
        let c = ProviderController(id: .ollama, adapter: adapter, profile: saved)
        await c.bootstrap()
        #expect(c.profile.port == 11434, "bootstrap replaces the stale saved port")
        #expect(c.apiURLEntries.first?.url == "http://127.0.0.1:11434",
                "the copied API URL uses the resolved port")
        c.updateProfile { $0.port = 9000 }
        #expect(c.profile.port == 11434, "the managed port stays read-only")
        #expect(c.portError != nil)
    }
}

@Suite("Review fix 8: kernel-backed memory readings")
struct MemoryReviewTests {
    @Test("pressure comes from the kernel and is available immediately")
    func kernelPressure() {
        let level = PressureMonitor.kernelPressureLevel()
        #expect(level != nil, "kern.memorystatus_vm_pressure_level must be readable")
        let monitor = PressureMonitor()
        monitor.start { _ in }
        #expect(monitor.currentState != .unknown,
                "start() must apply the kernel reading immediately")
        monitor.stop()
        #expect(monitor.currentState == .unknown, "stop() returns to Unavailable")
    }

    @Test("estimated used RAM excludes reclaimable file cache and stays sane")
    func estimatedUsed() throws {
        let sample = try #require(SystemMemorySampler().sample())
        let total = ProcessInfo.processInfo.physicalMemory
        #expect(sample.usedBytes > 0)
        #expect(sample.usedBytes <= total)
    }
}


// MARK: - Structured runtime options (per-provider knobs)

@Suite("Runtime options: structured per-provider knobs")
struct RuntimeOptionTests {
    // Fixtures throughout: these assert the exact argv, so they use a fixture
    // executable and model folder rather than an installed engine or a
    // personal model path.

    @Test("llama.cpp plan carries the knobs only when set")
    func llamaKnobs() throws {
        let gguf = "/private/tmp/arclatch-knobs-\(UUID().uuidString)/Qwen3-8B-Q4_K_M.gguf"
        defer { try? FileManager.default.removeItem(atPath: (gguf as NSString).deletingLastPathComponent) }
        try makeFixtureFile(gguf)
        var p = ProviderProfile(port: 8082, executablePath: fixtureExecutable, modelID: gguf)
        var plan = try LlamaCppAdapter().launchPlan(profile: p)
        #expect(!plan.arguments.contains("-c"))
        #expect(!plan.arguments.contains("-ngl"))
        #expect(!plan.arguments.contains("-t"))
        p.contextLength = 8192
        p.gpuLayers = 99
        p.threadCount = 8
        plan = try LlamaCppAdapter().launchPlan(profile: p)
        #expect(plan.arguments == ["-m", p.modelID,
                                   "--host", "127.0.0.1", "--port", "8082",
                                   "-c", "8192", "-ngl", "99", "-t", "8"])
    }

    @Test("MLX plan maps max tokens and temperature to its own flags")
    func mlxKnobs() throws {
        let dir = "/private/tmp/arclatch-mlx-knobs-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try makeFixtureFile(dir + "/config.json", "{}")
        try makeFixtureFile(dir + "/model.safetensors")
        var p = ProviderProfile(port: 8081, executablePath: fixtureExecutable, modelID: dir)
        p.allowCustomCode = true
        p.customCodeApprovedModel = p.modelID
        p.maxTokens = 512
        p.temperature = 0.7
        let plan = try MLXLMAdapter().launchPlan(profile: p)
        #expect(plan.arguments.contains("--max-tokens"))
        #expect(plan.arguments.contains("512"))
        #expect(plan.arguments.contains("--temp"))
        #expect(plan.arguments.contains("0.7"))
    }

    @Test("invalid knob values are refused and explained; valid ones persist")
    @MainActor
    func knobValidation() {
        let c = makeFakeController(script: FakeAdapter.Script())
        c.setContextLength(0)
        #expect(c.profile.contextLength == nil)
        #expect(c.configError != nil)
        c.setContextLength(8192)
        #expect(c.profile.contextLength == 8192)
        #expect(c.configError == nil)
        c.setTemperature(9)
        #expect(c.profile.temperature == nil)
        #expect(c.configError != nil)
        c.setTemperature(0.7)
        #expect(c.profile.temperature == 0.7)
        #expect(c.configError == nil)
        // Clearing returns the engine default.
        c.setContextLength(nil)
        #expect(c.profile.contextLength == nil)
    }
}

@Suite("Live provider status")
@MainActor
struct LiveProviderStatusTests {
    @Test("monitor detects an external server appearing and disappearing")
    func externalListenerLifecycle() async throws {
        let listener = try #require(bindListener(port: 0))
        var listenerOpen = true
        defer { if listenerOpen { close(listener) } }

        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        try #require(nameResult == 0)
        let port = Int(UInt16(bigEndian: address.sin_port))

        var script = FakeAdapter.Script()
        script.probeResult = .provider(modelID: "fixture-model",
                                       detail: "Fixture server", brewService: false)
        let adapter = FakeAdapter(id: .splash, script: script)
        let profile = ProviderProfile(port: port, executablePath: "/bin/sleep",
                                      modelID: "fixture-model")
        let controller = ProviderController(id: .splash, adapter: adapter, profile: profile)
        let monitor = Task { await controller.monitorEndpoint() }
        defer { monitor.cancel() }

        let detected = await poll { controller.status == .runningExternally(
            detail: "Fixture server", stopViaService: false) }
        try #require(detected)
        controller.runTest()
        let tested = await poll { controller.lastTest != nil }
        try #require(tested)
        controller.copyNote = "Copied URL"

        close(listener)
        listenerOpen = false

        let stopped = await poll { controller.status == .stopped }
        #expect(stopped)
        #expect(controller.canStart)
        #expect(!controller.canTest)
        #expect(!controller.canCopy)
        #expect(controller.lastTest == nil)
        #expect(controller.copyNote == nil)
        #expect(adapter.serviceStopCalls == 0)
    }
}

// MARK: - Stale status latch (profile edits must reconcile status at once)

/// A fake whose setup checks follow the profile: the model file check
/// passes only for ids prefixed "ok-", and ids containing "custom" add a
/// custom-code consent check — mirroring the MLX-LM repro where a model
/// change or consent toggle must clear/re-raise the blocker immediately.
final class SetupModelFake: ProviderAdapter, @unchecked Sendable {
    let id = ProviderID.llamacpp
    let displayName = "SetupModelFake"
    func models(profile: ProviderProfile) async -> [ModelChoice] { [] }
    func setupChecks(profile: ProviderProfile) -> [SetupCheck] {
        var checks = [SetupCheck(label: "Engine", ok: true)]
        let fileOK = profile.modelID.hasPrefix("ok-")
        checks.append(SetupCheck(label: "Model file", ok: fileOK,
                                 detail: fileOK ? nil : "model file missing"))
        if profile.modelID.contains("custom") {
            checks.append(SetupCheck(label: "Custom model code allowed",
                                     ok: profile.customCodeActive,
                                     detail: profile.customCodeActive
                                        ? nil : "This model needs custom code — enable it"))
        }
        return checks
    }
    func launchPlan(profile: ProviderProfile) throws -> LaunchPlan {
        throw LaunchPlanError("not launched in this test")
    }
    func probe(port: Int, profile: ProviderProfile) async -> ProbeResult { .closed }
    func isReady(port: Int, profile: ProviderProfile) async -> Bool { false }
    func test(port: Int, profile: ProviderProfile) async -> GenerationOutcome { .failed("n/a") }
    func apiURLs(port: Int, profile: ProviderProfile) -> [APIURLEntry] { [] }
}

@Suite("Bug 1: profile edits recompute the setup status")
@MainActor
struct SetupStatusRecomputeTests {
    private func controller(modelID: String) -> ProviderController {
        ProviderController(id: .llamacpp, adapter: SetupModelFake(),
                           profile: ProviderProfile(port: 59988,
                                                    executablePath: "/bin/sleep",
                                                    modelID: modelID))
    }

    @Test("model change clears Needs setup and re-blocks immediately")
    func modelChangeRecomputesStatus() async {
        let c = controller(modelID: "broken-model")
        await c.bootstrap()
        guard case .needsSetup(let msg) = c.status else {
            Issue.record("expected needsSetup for a missing model, got \(c.status)"); return
        }
        #expect(msg.contains("Model file"))
        c.updateProfile { $0.modelID = "ok-model" }
        #expect(c.status == .stopped,
                "fixing the model must clear the stale Needs setup at once")
        c.updateProfile { $0.modelID = "broken-model" }
        guard case .needsSetup(let again) = c.status else {
            Issue.record("expected needsSetup again, got \(c.status)"); return
        }
        #expect(again.contains("Model file"))
    }

    @Test("custom-code toggle clears its blocker without a new start attempt")
    func customCodeToggle() async {
        let c = controller(modelID: "ok-custom")
        await c.bootstrap()
        if case .needsSetup(let msg) = c.status {
            #expect(msg.contains("Custom model code allowed"))
        } else {
            Issue.record("expected needsSetup for a consent-gated model, got \(c.status)")
            return
        }
        c.updateProfile {
            $0.allowCustomCode = true
            $0.customCodeApprovedModel = $0.modelID
        }
        #expect(c.status == .stopped, "enabling consent must clear the blocker immediately")
        c.updateProfile { $0.allowCustomCode = false }
        if case .needsSetup = c.status {} else {
            Issue.record("removing consent must re-block, got \(c.status)")
        }
    }

    @Test("Re-check (bootstrap) clears a stale Needs setup once checks pass")
    func recheckClearsStaleNeedsSetup() async {
        let c = controller(modelID: "ok-model")
        // A needsSetup latch that outlived its cause — the exact state the
        // bug leaves behind for the whole session.
        c.status = .needsSetup("stale blocker that no longer applies")
        await c.bootstrap()
        #expect(c.status == .stopped,
                "Re-check must not keep a blocker the setup checks no longer have")
    }
}

// MARK: - Numeric text fields: digits only, RAM sanity, error retention

@Suite("Bug 2: digit-only numeric input and RAM sanity estimate")
struct NumericInputTests {
    @Test("digitsOnly drops separators, signs, spaces, and non-ASCII digits")
    func sanitize() {
        #expect(NumericInput.digitsOnly("8,082") == "8082")
        #expect(NumericInput.digitsOnly("-45") == "45")
        #expect(NumericInput.digitsOnly("c 899192 x") == "899192")
        #expect(NumericInput.digitsOnly("٩٩٩") == "",
                "non-ASCII digits never reach an Int binding")
        #expect(NumericInput.digitsOnly("") == "")
    }

    @Test("parse: empty means default, overflow is rejected not clamped")
    func parse() {
        #expect(NumericInput.parse("") == nil)
        #expect(NumericInput.parse("01024") == 1024)
        #expect(NumericInput.parse("899192") == 899192)
        #expect(NumericInput.parse("99999999999999999999") == nil,
                "an Int-overflow entry must not be silently clamped")
        // The old grouping corruption: 99999999 committed as 899192.
        // Sanitized digit input must now survive as exactly itself.
        #expect(NumericInput.parse(NumericInput.digitsOnly("99,999,999")) == 99_999_999)
    }

    @Test("RAM sanity warns only when the KV estimate dwarfs physical RAM")
    func ramSanity() {
        let big = UInt64(128) * 1_073_741_824   // 128 GiB machine
        #expect(RAMSanity.warning(contextLength: 8_192, physicalMemoryBytes: big) == nil)
        #expect(RAMSanity.warning(contextLength: 131_072, physicalMemoryBytes: big) == nil)
        let warn = RAMSanity.warning(contextLength: 899_192, physicalMemoryBytes: big)
        #expect(warn?.contains("899,192") == true, "token count rendered grouped")
        #expect(warn?.contains("128 GB") == true)
        // A small machine flags what a big one tolerates: one heuristic,
        // scaled by physical RAM.
        let small = UInt64(16) * 1_073_741_824
        #expect(RAMSanity.warning(contextLength: 65_536, physicalMemoryBytes: small) != nil)
        #expect(RAMSanity.warning(contextLength: 8_192, physicalMemoryBytes: small) == nil)
        // Degenerate inputs never warn and never crash.
        #expect(RAMSanity.warning(contextLength: 0, physicalMemoryBytes: big) == nil)
        #expect(RAMSanity.warning(contextLength: 4096, physicalMemoryBytes: 0) == nil)
    }
}

@Suite("Bug 2: refused numeric edits stay visible until a change lands")
@MainActor
struct ConfigErrorRetentionTests {
    @Test("re-committing the unchanged value does not clear a shown error")
    func recommitKeepsError() {
        let c = makeFakeController(script: FakeAdapter.Script())
        c.setContextLength(8192)
        #expect(c.configError == nil)
        c.setContextLength(0)                 // out of range → refused
        #expect(c.configError != nil)
        #expect(c.profile.contextLength == 8192,
                "a refused edit must never change the stored value")
        c.setContextLength(8192)              // re-commit of the old value
        #expect(c.configError != nil, "a re-commit must not wipe the shown error")
        c.setContextLength(16384)             // a fix actually lands → error clears
        #expect(c.profile.contextLength == 16384)
        #expect(c.configError == nil)
    }

    @Test("clearing a field commits the engine default and clears the error")
    func clearCommitsDefault() {
        let c = makeFakeController(script: FakeAdapter.Script())
        c.setContextLength(8192)
        c.setContextLength(0)
        #expect(c.configError != nil)
        c.setContextLength(nil)               // empty field = engine default, a real change
        #expect(c.profile.contextLength == nil)
        #expect(c.configError == nil)
    }
}

// MARK: - Ready transitions refresh the model list (no manual Rescan)

@Suite("Bug 3: ready transitions schedule a model list refresh")
@MainActor
struct ReadyTransitionModelRefreshTests {
    @Test("Start reaching ready refreshes the model list")
    func startReadyRefreshesModels() async {
        var script = FakeAdapter.Script()
        script.readyDelay = 0.3
        let adapter = FakeAdapter(id: .llamacpp, script: script)
        let c = ProviderController(id: .llamacpp, adapter: adapter,
                                   profile: ProviderProfile(port: 59987,
                                                            executablePath: "/bin/sleep",
                                                            modelID: "fake-a"))
        await c.bootstrap()
        let initial = adapter.modelListCalls
        #expect(initial == 1, "bootstrap lists models once")
        c.start()
        let ready = await poll { c.status == .ready }
        #expect(ready, "expected ready, got \(c.status)")
        let refreshed = await poll { adapter.modelListCalls > initial }
        #expect(refreshed, "transition to ready must schedule a model refresh")
        c.stop()
        _ = await poll { c.status == .stopped }
    }

    @Test("an external server appearing on the port refreshes the model list")
    func externalServerRefreshesModels() async {
        var script = FakeAdapter.Script()
        script.probeResult = .provider(modelID: nil, detail: "svc", brewService: false)
        let adapter = FakeAdapter(id: .ollama, script: script)
        let c = ProviderController(id: .ollama, adapter: adapter,
                                   profile: ProviderProfile(port: 59986,
                                                            executablePath: "/bin/sleep",
                                                            modelID: "svc"))
        await c.bootstrap()   // port closed at bootstrap: no tags yet
        #expect(c.status == .stopped)
        #expect(adapter.modelListCalls == 1)
        guard let fd = bindListener(port: 59986) else { return }
        defer { close(fd) }
        await c.refreshEndpoint()
        if case .runningExternally = c.status {} else {
            Issue.record("expected runningExternally, got \(c.status)"); return
        }
        let refreshed = await poll { adapter.modelListCalls == 2 }
        #expect(refreshed, "transition to runningExternally must refresh the model list")
    }
}

// MARK: - Start-time RAM fit estimate (stubbed filesystem sizes + stubbed RAM)

@Suite("Start RAM fit estimate")
struct StartMemoryEstimateTests {
    private struct StubWeights: ModelWeightSizing {
        var bytes: UInt64?
        func weightBytes(provider: ProviderID, modelID: String) -> UInt64? { bytes }
    }
    private struct StubFree: FreeMemorySampling {
        var bytes: UInt64?
        func freeBytes() -> UInt64? { bytes }
    }
    private let gib: UInt64 = 1024 * 1024 * 1024

    @Test("required = weights + RAMSanity's KV allowance; fits flags both outcomes")
    func fitMath() throws {
        var profile = ProviderProfile(port: 8082, executablePath: "/x/llama-server",
                                      modelID: "/models/Q4_K_M.gguf")
        profile.contextLength = 8192
        // RAMSanity.kvMBPerToken (0.15 MB/token) is the single documented
        // source: 8192 tokens → 1228.8 MiB.
        let kv = UInt64((8192 * RAMSanity.kvMBPerToken * 1_048_576).rounded())
        #expect(kv == 1_288_490_189)

        let roomy = try #require(StartMemoryCheck.estimate(
            provider: .llamacpp, profile: profile,
            weights: StubWeights(bytes: 5 * gib), free: StubFree(bytes: 11 * gib)))
        #expect(roomy.kvBytes == kv)
        #expect(roomy.requiredBytes == 5 * gib + kv)
        #expect(roomy.fits)
        #expect(roomy.caption == "Model ≈ 5.0 GB · ~11 GB free")

        let tight = try #require(StartMemoryCheck.estimate(
            provider: .llamacpp, profile: profile,
            weights: StubWeights(bytes: 5 * gib), free: StubFree(bytes: 4 * gib)))
        #expect(!tight.fits)
        #expect(tight.caption.contains("may not fit"),
                "weights + KV over available must say so: \(tight.caption)")
    }

    @Test("KV ties to the RAMSanity constant; unset context uses the documented default")
    func kvSource() {
        #expect(StartMemoryCheck.kvBytes(contextLength: 1000)
                == UInt64((1000 * RAMSanity.kvMBPerToken * 1_048_576).rounded()))
        #expect(StartMemoryCheck.kvBytes(contextLength: nil)
                == StartMemoryCheck.kvBytes(contextLength: StartMemoryCheck.defaultContextTokens))
        #expect(StartMemoryCheck.kvBytes(contextLength: 0) == 0)
    }

    @Test("no guessing: external stores and unmeasurable inputs give no estimate")
    func noGuessing() {
        // Ollama and Splash serve from internal stores: the real sizing
        // says nothing, so the estimate is nil — never a wrong number.
        let ollama = ProviderProfile.defaults(for: .ollama)
        #expect(StartMemoryCheck.estimate(provider: .ollama, profile: ollama,
                                          weights: FileSystemModelWeights(),
                                          free: StubFree(bytes: 20 * gib)) == nil)
        let splash = ProviderProfile.defaults(for: .splash)
        #expect(StartMemoryCheck.estimate(provider: .splash, profile: splash,
                                          weights: FileSystemModelWeights(),
                                          free: StubFree(bytes: 20 * gib)) == nil)
        // A llama.cpp profile whose GGUF is not on disk measures nothing.
        let missing = "/private/tmp/arclatch-no-such-model.gguf"
        #expect(FileSystemModelWeights().weightBytes(provider: .llamacpp,
                                                     modelID: missing) == nil)
        // No RAM reading: no estimate, not a guess.
        var llama = ProviderProfile.defaults(for: .llamacpp)
        llama.modelID = missing
        #expect(StartMemoryCheck.estimate(provider: .llamacpp, profile: llama,
                                          weights: StubWeights(bytes: gib),
                                          free: StubFree(bytes: nil)) == nil)
    }

    @Test("MLX sizing sums only the .safetensors weights in the model folder")
    func mlxWeightSum() throws {
        let fm = FileManager.default
        let root = "/private/tmp/arclatch-ramsize-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 1024)
            .write(to: URL(fileURLWithPath: root + "/model-00001-of-00002.safetensors"))
        try Data(repeating: 7, count: 2048)
            .write(to: URL(fileURLWithPath: root + "/model-00002-of-00002.safetensors"))
        try "{}".write(toFile: root + "/config.json", atomically: true, encoding: .utf8)
        try Data(repeating: 0, count: 999)
            .write(to: URL(fileURLWithPath: root + "/extras.bin"))
        #expect(FileSystemModelWeights().weightBytes(provider: .mlxlm,
                                                     modelID: root) == 3072,
                "shards sum; non-weight files stay out")
    }
}
