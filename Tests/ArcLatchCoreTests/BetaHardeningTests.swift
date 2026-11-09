import Testing
import Foundation
import Darwin
@testable import ArcLatchCore

// Beta-hardening coverage: service cleanup decided by the service manager's
// identity rather than by a port, and the short model name a result banner
// shows. Everything here is hermetic: the service manager is a fake, no real
// `launchctl` or `brew` process is ever run, and the only processes involved
// are the established /bin/sleep and /bin/sh launch fixtures.

// MARK: - Fake service manager

/// Stands in for the service manager: the test decides what is registered.
final class FakeRegistrar: ServiceRegistrar, @unchecked Sendable {
    private let lock = NSLock()
    private var state: ServiceRegistration
    private var targetsSeen: [String] = []
    let labelList: [String]

    init(labels: [String] = [OllamaAdapter.launchAgentLabel],
         state: ServiceRegistration = .notRegistered) {
        self.labelList = labels
        self.state = state
    }

    var targets: [String] { labelList.map { "gui/\(getuid())/\($0)" } }

    func setState(_ next: ServiceRegistration) {
        lock.lock(); state = next; lock.unlock()
    }

    /// Every identity the code asked about — the assertion that the query
    /// names Homebrew's exact agent, not something guessed.
    var queriedTargets: [String] {
        lock.lock(); defer { lock.unlock() }
        return targetsSeen
    }

    /// One locked step: record the identity that was asked about, answer with
    /// the current registration.
    private func noteQuery(_ names: [String]) -> ServiceRegistration {
        lock.lock(); defer { lock.unlock() }
        targetsSeen.append(contentsOf: names)
        return state
    }

    func registration() async -> ServiceRegistration { noteQuery(targets) }
}

// MARK: - Registration decides what is ArcLatch's to shut down

@Suite("Ollama cleanup is decided by service identity, not by the port")
struct ServiceIdentityTests {
    @Test("the adapter asks about Homebrew's exact LaunchAgent identity")
    func exactIdentityQueried() async {
        let reg = FakeRegistrar()
        let adapter = OllamaAdapter(plistPath: "/private/tmp/arclatch-no-such.plist",
                                    registrar: reg)
        #expect(adapter.managedServiceLabel == "homebrew.mxcl.ollama")
        #expect(await adapter.serviceRegistration() == .notRegistered)
        #expect(reg.queriedTargets.contains("gui/\(getuid())/homebrew.mxcl.ollama"),
                "the query must name the agent: \(reg.queriedTargets)")
    }

    @Test("launchctl answers classify as registered, stopping, gone, or unknown")
    func classifyLaunchctlAnswers() {
        // A loaded agent: launchctl prints its details and exits 0.
        #expect(LaunchctlRegistrar.classify(status: 0, output: """
            gui/501/homebrew.mxcl.ollama = <launchd: Label:"homebrew.mxcl.ollama">
                state = running
                path = /Users/me/Library/LaunchAgents/homebrew.mxcl.ollama.plist
            """) == .registered)
        #expect(LaunchctlRegistrar.classify(status: 0,
                                           output: "state = stopping") == .stopping)
        // The real "not loaded" answer, exactly as launchctl words it:
        #expect(LaunchctlRegistrar.classify(status: 3, output: """
            Bad request.
            Could not find service "homebrew.mxcl.ollama" in domain for user gui: 501
            """) == .notRegistered)
        // A query that failed is not proof of absence.
        #expect(LaunchctlRegistrar.classify(status: 1,
                                           output: "operation not permitted") == .unknown)
    }

    @Test("an unconfirmed stop is a failed stop: ownership stays with ArcLatch")
    func stopOutcomeRequiresUnregistration() {
        let label = OllamaAdapter.launchAgentLabel
        #expect(OllamaAdapter.stopOutcome(brewSucceeded: true,
                                          registration: .notRegistered,
                                          label: label) == .ok)

        let still = OllamaAdapter.stopOutcome(brewSucceeded: true,
                                              registration: .registered, label: label)
        if case .failed(let message) = still {
            #expect(message.contains(label), "\(label) must be named: \(message)")
            #expect(message.contains("registered"), "must say it is registered: \(message)")
        } else {
            Issue.record("a still-registered service must not read as stopped: \(still)")
        }

        let stopping = OllamaAdapter.stopOutcome(brewSucceeded: true,
                                                 registration: .stopping, label: label)
        if case .failed(let message) = stopping {
            #expect(message.contains("stopping"), "must say it is still stopping: \(message)")
        } else {
            Issue.record("a service still being torn down must not read as stopped")
        }

        let unverifiable = OllamaAdapter.stopOutcome(brewSucceeded: true,
                                                     registration: .unknown, label: label)
        if case .failed(let message) = unverifiable {
            #expect(message.contains("could not confirm"),
                    "must admit it could not confirm: \(message)")
        } else {
            Issue.record("an unverifiable stop must not read as ok")
        }
    }
}

// MARK: - Cancel and quit retain ownership until shutdown is confirmed

@Suite("Round 4: cancel and quit confirm the agent is gone")
@MainActor
struct ServiceShutdownConfirmationTests {
    /// A service-managed fake whose port **never opens**: the scenario a port
    /// probe cannot answer — the service is registered and still coming up.
    private func serviceController(port: Int,
                                   registration: ServiceRegistration,
                                   clearsOnStop: Bool) -> (ProviderController, FakeAdapter) {
        var script = FakeAdapter.Script()
        script.serviceManaged = true
        script.serviceStartDelay = 0.4          // start still in flight on cancel
        script.readyDelay = 60                  // never reaches ready
        script.serviceRegistration = registration
        script.serviceClearsRegistrationOnStop = clearsOnStop
        script.probeResult = .provider(modelID: nil, detail: "svc", brewService: true)
        let adapter = FakeAdapter(id: .ollama, script: script)
        let c = ProviderController(id: .ollama, adapter: adapter,
                                   profile: ProviderProfile(port: port,
                                                            executablePath: fixtureExecutable,
                                                            modelID: "svc"))
        return (c, adapter)
    }

    @Test("cancel during a start stops a registered, not-yet-listening service and confirms it")
    func cancelConfirmsShutdown() async {
        let (c, adapter) = serviceController(port: 47890, registration: .registered,
                                             clearsOnStop: true)
        c.start()
        _ = await poll { adapter.serviceStartCalls == 1 }
        #expect(c.status == .starting)
        #expect(!PortInspector.isListening(port: 47890, timeoutMS: 200),
                "the port is closed: only the registration answer can decide")

        c.cancelStart()
        #expect(c.requiresShutdown, "a cancelled start is still ArcLatch's to clean up")
        let settled = await poll(timeout: 20) {
            c.busy == .none && c.status == .stopped && !c.ownsManagedService
        }
        #expect(settled, "cancel must settle once the agent is gone, got \(c.status), busy \(c.busy)")
        #expect(adapter.serviceStopCalls == 1, "the service ArcLatch started is stopped once")
    }

    @Test("a cleanup whose agent stays registered is reported, and ownership is kept")
    func unconfirmedCleanupRetainsOwnership() async {
        // The service manager says "still registered" even after the stop
        // request succeeds: ArcLatch must not pretend the service is down.
        let (c, adapter) = serviceController(port: 47891, registration: .registered,
                                             clearsOnStop: false)
        c.start()
        let owned = await poll { c.ownsManagedService }
        #expect(owned, "the start request should complete with the port still closed")

        c.cancelStart()
        let settled = await poll(timeout: 20) { c.busy == .none && c.status.isFailureLike }
        if !settled {
            Issue.record("unconfirmed cleanup must settle as a failure, got \(c.status), busy \(c.busy)")
        }
        if case .failed(let message) = c.status {
            #expect(message.contains("service running"), "says the service survived: \(message)")
        }
        #expect(c.ownsManagedService, "ownership is retained until shutdown is confirmed")
        #expect(c.requiresShutdown, "a later quit still targets this provider")
        #expect(c.canStop, "Stop stays available to retry the cleanup")
        #expect(adapter.serviceStopCalls == 1, "exactly one stop request per cleanup")
    }

    @Test("quit stops and confirms a registered service that never opened its port")
    func quitWhileRegistered() async {
        let (c, adapter) = serviceController(port: 47892, registration: .registered,
                                             clearsOnStop: true)
        c.start()
        let owned = await poll { c.ownsManagedService }
        #expect(owned)
        #expect(!PortInspector.isListening(port: 47892, timeoutMS: 200))

        let decision = await QuitGate.shutdown(controllers: [c])
        #expect(decision.shutdownRequested)
        #expect(decision.failures.isEmpty, "quit must confirm shutdown: \(decision.failures)")
        #expect(adapter.serviceStopCalls == 1)
        #expect(!c.ownsManagedService)
    }

    @Test("quit is refused while the agent is still registered")
    func quitRefusedWhileStillRegistered() async {
        let (c, adapter) = serviceController(port: 47893, registration: .registered,
                                             clearsOnStop: false)
        c.start()
        let owned = await poll { c.ownsManagedService }
        #expect(owned)

        let decision = await QuitGate.shutdown(controllers: [c])
        #expect(decision.failures == ["Ollama"],
                "a service still in the bootstrap must keep the app open: \(decision.failures)")
        #expect(c.ownsManagedService, "ownership survives the refused quit")
        #expect(c.requiresShutdown)
        #expect(adapter.serviceStopCalls == 1)
    }

    @Test("a service ArcLatch did not start is never touched, registered or not")
    func foreignRegisteredServiceUntouched() async {
        let (c, adapter) = serviceController(port: 47894, registration: .registered,
                                             clearsOnStop: true)
        await c.bootstrap()   // nothing listening: ArcLatch takes no ownership
        #expect(c.status == .stopped)
        #expect(!c.ownsManagedService)
        #expect(!c.canStop, "no Stop affordance for a service that is not ours")

        let decision = await QuitGate.shutdown(controllers: [c])
        #expect(!decision.shutdownRequested,
                "the quit gate must not target someone else's service")
        #expect(adapter.serviceStopCalls == 0, "no stop request, ever")
        #expect(adapter.serviceStartCalls == 0)
    }
}

// MARK: - Short model names in result banners

@Suite("Result banners use the short model name")
struct ModelDisplayNameTests {
    @Test("each provider's short form, with paths and extensions left out")
    func shortNames() {
        let llama = ProviderProfile(port: 8082, executablePath: "/x/llama-server",
                                    modelID: "/Users/me/models/Qwen3-8B-Q4_K_M.gguf")
        #expect(ModelDisplayName.short(provider: .llamacpp, profile: llama) == "Qwen3-8B-Q4_K_M")
        // What the server reported wins, and is shortened the same way: an
        // absolute path back from the API never reaches the banner.
        #expect(ModelDisplayName.short(provider: .llamacpp, profile: llama,
                                       reported: "/Users/me/models/Qwen3-8B-Q4_K_M.gguf")
                == "Qwen3-8B-Q4_K_M")

        // Only ".gguf" goes: a dotted quant tag stays part of the name.
        let dotted = ProviderProfile(port: 8082, executablePath: "/x/llama-server",
                                     modelID: "/m/DeepSeek-R1.DS-1.58Bit.gguf")
        #expect(ModelDisplayName.short(provider: .llamacpp, profile: dotted)
                == "DeepSeek-R1.DS-1.58Bit")

        let splash = ProviderProfile(port: 8000, executablePath: "/x/splash",
                                     modelID: "ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:IQ3_S")
        #expect(ModelDisplayName.short(provider: .splash, profile: splash)
                == "Qwen3.8-Flash-Next-GSQ-RCO-GGUF:IQ3_S")

        let mlx = ProviderProfile(port: 8081, executablePath: "/x/mlx_lm.server",
                                  modelID: "/Users/me/models/Ripple-65B-Preview-MLX-4bit")
        #expect(ModelDisplayName.short(provider: .mlxlm, profile: mlx)
                == "Ripple-65B-Preview-MLX-4bit")

        let ollama = ProviderProfile(port: 11434, executablePath: "/x/ollama",
                                     modelID: "qwen3:8b")
        #expect(ModelDisplayName.short(provider: .ollama, profile: ollama) == "qwen3:8b")
    }

    @Test("a short name never carries a path or a .gguf suffix")
    func noPathsInShortNames() {
        let cases: [(ProviderID, String)] = [
            (.llamacpp, "/Users/me/AI/models/DeepSeek-00001-of-00004.gguf"),
            (.mlxlm, "/Users/me/AI/models/lmstudio/frogggias/Ripple-65B-Preview-MLX-4bit"),
            (.splash, "org/Model:VARIANT"),
        ]
        for (provider, modelID) in cases {
            let profile = ProviderProfile(port: 1, executablePath: "/x", modelID: modelID)
            let name = ModelDisplayName.short(provider: provider, profile: profile)
            #expect(!name.contains("/"), "\(provider): \(name)")
            #expect(!name.lowercased().hasSuffix(".gguf"), "\(provider): \(name)")
            #expect(!name.isEmpty, "\(provider)")
        }
    }
}
