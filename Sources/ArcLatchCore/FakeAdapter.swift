import Foundation

/// A scriptable fake adapter: it drives the whole UI through start, cancel,
/// ready, test, and error states without touching real engines. Used by
/// development previews (ARC_LATCH_FAKE=1) and by tests.
public final class FakeAdapter: ProviderAdapter, @unchecked Sendable {
    public let id: ProviderID
    public let displayName: String

    public struct Script {
        public init() {}
        public var startDelay: TimeInterval = 1.2
        public var failsToLaunch = false
        public var launchExitCode: Int32 = 3
        public var launchLog = "simulated engine error: model file unreadable"
        public var readyDelay: TimeInterval = 1.2
        public var failsToBecomeReady = false
        public var testOutcome: GenerationOutcome = .passed(modelReported: "fake-model")
        /// Seconds the fake subprocess lives; short values exercise the
        /// early-exit path.
        public var holdSeconds: Double = 120
        /// Crash fixtures for the exit-reason path: when set, the fake
        /// launch is a short-lived /bin/sh (same fixture pattern as
        /// /bin/sleep, no engine involved) that exits nonzero, or kills
        /// itself with SIGKILL, after `crashDelay` seconds.
        public var crashExitCode: Int32? = nil
        public var crashBySignal = false
        public var crashDelay: TimeInterval = 1.0
        public var readinessTimeout: TimeInterval = 4
        public var modelChoices: [ModelChoice] = [
            ModelChoice(id: "fake-a", label: "Fake Model A", detail: "/models/fake-a.gguf"),
            ModelChoice(id: "fake-b", label: "Fake Model B", detail: "/models/fake-b.gguf"),
        ]
        public var setupFails = false
        /// Exercises the Homebrew-service lifecycle with no real service.
        public var serviceManaged = false
        public var probeResult: ProbeResult = .closed
        /// Suspends startService this long, to exercise quit during a
        /// still-suspended service start.
        public var serviceStartDelay: TimeInterval = 0
        /// Pretends the managed service is configured for this port.
        public var configuredPort: Int?
        /// Makes stopService fail, to exercise failed-cleanup retention.
        public var serviceStopFails = false
        /// What the fake service manager says about the service's registration
        /// identity: `.registered` / `.stopping` model a service that is still
        /// in the bootstrap (with a port that may never have opened),
        /// `.notRegistered` a service that is really gone.
        public var serviceRegistration: ServiceRegistration = .notRegistered
        /// False keeps the agent registered after stopService, to exercise the
        /// "stop requested, shutdown not confirmed" path.
        public var serviceClearsRegistrationOnStop = true
    }

    private let script: Script
    private let clockStart = Date()
    public private(set) var serviceStartCalls = 0
    public private(set) var serviceStopCalls = 0
    /// The fake service manager's current answer, driven by the script and by
    /// stopService. No real service manager is ever contacted.
    private var registration: ServiceRegistration
    /// How many times the model list was requested (bootstrap, Rescan,
    /// automatic refresh on a ready transition). Tests assert against this
    /// without spawning any real listing process.
    public private(set) var modelListCalls = 0
    /// The profile the last generation test was asked to run against.
    public private(set) var lastTestProfile: ProviderProfile?

    public init(id: ProviderID, script: Script = Script()) {
        self.id = id
        self.displayName = id.displayName + " (demo)"
        self.script = script
        self.registration = script.serviceRegistration
    }

    public var serviceManagedLaunch: Bool { script.serviceManaged }
    public var managedServiceLabel: String { "homebrew.mxcl.demo" }

    public func serviceRegistration() async -> ServiceRegistration { registration }

    public func models(profile: ProviderProfile) async -> [ModelChoice] {
        modelListCalls += 1
        return script.modelChoices
    }

    public func setupChecks(profile: ProviderProfile) -> [SetupCheck] {
        [SetupCheck(label: "Demo engine", ok: !script.setupFails,
                    detail: script.setupFails ? "demo executable missing" : nil)]
    }

    public func configuredServicePort(profile: ProviderProfile) -> Int? {
        script.configuredPort
    }

    public func startService(port: Int) async -> ServiceResult {
        serviceStartCalls += 1
        if script.serviceStartDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(script.serviceStartDelay * 1_000_000_000))
        }
        return .ok
    }

    public func stopService(port: Int) async -> ServiceResult {
        serviceStopCalls += 1
        if script.serviceStopFails { return .failed("simulated brew services stop failure") }
        // The fake manager confirms teardown the way the real one must: the
        // registration identity leaves the bootstrap.
        if script.serviceClearsRegistrationOnStop { registration = .notRegistered }
        return .ok
    }

    public func launchPlan(profile: ProviderProfile) throws -> LaunchPlan {
        if script.serviceManaged {
            throw LaunchPlanError("service only")
        }
        if script.failsToLaunch {
            throw LaunchPlanError(script.launchLog)
        }
        // Crash fixtures: /bin/sh exiting with a code, or SIGKILLing
        // itself, exercises the crash-surfacing path with the same
        // subprocess-fixture pattern as /bin/sleep — no engine, no service.
        if script.crashBySignal {
            return LaunchPlan(
                execURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep \(script.crashDelay); kill -9 $$"],
                environment: baseLaunchEnvironment(),
                workingDirectory: URL(fileURLWithPath: NSHomeDirectory()),
                readinessTimeout: script.readinessTimeout,
                testTimeout: 10)
        }
        if let code = script.crashExitCode {
            return LaunchPlan(
                execURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep \(script.crashDelay); exit \(code)"],
                environment: baseLaunchEnvironment(),
                workingDirectory: URL(fileURLWithPath: NSHomeDirectory()),
                readinessTimeout: script.readinessTimeout,
                testTimeout: 10)
        }
        // /bin/sleep keeps a real short-lived subprocess under ownership so
        // stop, cancel, and early-exit paths exercise the process layer.
        return LaunchPlan(
            execURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: [String(script.holdSeconds)],
            environment: baseLaunchEnvironment(),
            workingDirectory: URL(fileURLWithPath: NSHomeDirectory()),
            readinessTimeout: script.readinessTimeout,
            testTimeout: 10)
    }

    public func probe(port: Int, profile: ProviderProfile) async -> ProbeResult {
        script.probeResult
    }

    public func isReady(port: Int, profile: ProviderProfile) async -> Bool {
        if script.failsToBecomeReady { return false }
        let elapsed = Date().timeIntervalSince(clockStart)
        return elapsed >= script.readyDelay
    }

    public func test(port: Int, profile: ProviderProfile) async -> GenerationOutcome {
        lastTestProfile = profile
        try? await Task.sleep(nanoseconds: UInt64(0.4 * 1_000_000_000))
        return script.testOutcome
    }

    public func apiURLs(port: Int, profile: ProviderProfile) -> [APIURLEntry] {
        [APIURLEntry(label: "Demo API", url: "http://127.0.0.1:\(port)/v1")]
    }
}
