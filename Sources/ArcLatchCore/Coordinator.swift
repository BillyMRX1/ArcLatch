import Foundation
import Combine

public enum ServerStatus: Equatable {
    case stopped
    case starting
    case ready
    case runningExternally(detail: String, stopViaService: Bool)
    case portConflict(String)
    case failed(String)
    case needsSetup(String)

    public var sidebarText: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .ready: return "Server ready"
        case .runningExternally: return "Running"
        case .portConflict: return "Port in use"
        case .failed: return "Failed"
        case .needsSetup: return "Needs setup"
        }
    }
}

extension ServerStatus {
    public var isFailureLike: Bool {
        switch self {
        case .failed, .needsSetup, .portConflict: return true
        default: return false
        }
    }
}

public enum BusyAction: Equatable {
    case none, starting, stopping, testing
}

/// One controller per provider: owns process lifecycle, managed-service
/// lifecycle, session guarding, logs, and test state. The UI observes it;
/// the adapter keeps provider specifics isolated.
@MainActor
public final class ProviderController: ObservableObject, Identifiable {
    public let id: ProviderID
    public let adapter: any ProviderAdapter
    public weak var store: ProfileStore?

    @Published public var profile: ProviderProfile
    @Published public var status: ServerStatus = .stopped
    @Published public var busy: BusyAction = .none
    @Published public var modelChoices: [ModelChoice] = []
    @Published public var lastTest: LastTest?
    @Published public var logs: [String] = []
    @Published public var checks: [SetupCheck] = []
    @Published public var copyNote: String?
    @Published public var portError: String?
    /// Explanation for a refused runtime-option or model-picking edit.
    @Published public var configError: String?

    public var onProfileChange: (() -> Void)?

    private var owned: ProcessController?
    /// True only when ArcLatch itself ran the managed-service start and has
    /// not stopped it. A pre-existing or external service never sets this,
    /// so cleanup after cancel/timeout/quit never touches someone else's.
    private var managedService = false
    /// Sessions whose startService call is still suspended. Quit must wait
    /// for these to settle before deciding there is nothing of ours to stop.
    private var pendingServiceStarts: Set<Int> = []
    /// One shared cleanup task so quit, cancel, and the cancelled-start
    /// cleanup can never race each other with duplicate service stops.
    private var serviceCleanup: Task<Bool, Never>?
    /// Set once a quit shutdown has begun: starts are refused so a retry
    /// cannot race the previous attempt's cleanup.
    private var quitting = false
    /// The profile actually used for the current owned launch; generation
    /// tests run against this while the server runs, not a later edit.
    private var launchedProfile: ProviderProfile?
    private var session: Int = 0
    private var refreshingEndpoint = false

    public init(id: ProviderID, adapter: any ProviderAdapter,
                profile: ProviderProfile, store: ProfileStore? = nil) {
        self.id = id
        self.adapter = adapter
        self.profile = profile
        self.store = store
    }

    // MARK: Derived UI state

    public var isOwnedRunning: Bool { owned?.isRunning ?? false }
    public var ownsManagedService: Bool { managedService }

    /// Single source of truth for "ArcLatch still holds something of this
    /// provider's to shut down": an owned process, an ArcLatch-started
    /// service, a service start still in flight (even after cancel cleared
    /// the visible starting state), an in-flight cleanup task, or a start/
    /// stop that has not settled. The quit gate and the shutdown target
    /// selection must both use this so a cancelled-but-still-pending start
    /// can never slip past quit.
    public var requiresShutdown: Bool {
        owned != nil || managedService
            || !pendingServiceStarts.isEmpty || serviceCleanup != nil
            || status == .starting || busy == .starting || busy == .stopping
    }

    public var canStart: Bool {
        busy == .none && !quitting
            && (status == .stopped || status.isFailureLike)
            && isValidPort(profile.port)
    }
    public var canStop: Bool {
        guard busy == .none else { return false }
        switch status {
        case .ready: return isOwnedRunning || managedService
        case .runningExternally(_, let viaService): return viaService
        case .failed:
            // A failed stop/cleanup retains ownership; Stop stays available
            // so the user can retry it without losing the service handle.
            return isOwnedRunning || managedService
        default: return false
        }
    }
    public var isEndpointReady: Bool {
        switch status {
        case .ready, .runningExternally: return true
        default: return false
        }
    }
    public var canTest: Bool { busy == .none && isEndpointReady }
    public var canCopy: Bool { isEndpointReady }

    public var detailStatusText: String {
        switch status {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .ready: return "Server ready"
        case .runningExternally(let detail, let viaService):
            return viaService ? "Running · \(detail)" : "Running externally"
        case .portConflict(let m): return m
        case .failed(let m): return m
        case .needsSetup(let m): return m
        }
    }

    public var apiURLEntries: [APIURLEntry] {
        adapter.apiURLs(port: profile.port, profile: profile)
    }

    // MARK: Bootstrap

    public func bootstrap() async {
        portError = isValidPort(profile.port) ? nil : portRangeMessage

        // A managed service owns its own configuration: adopt the port it is
        // actually configured for (e.g. Ollama's LaunchAgent OLLAMA_HOST,
        // defaulting to 11434). Any stale saved override is replaced, and
        // discovery, readiness, generation, and Stop all use this port.
        if adapter.serviceManagedLaunch,
           let configured = adapter.configuredServicePort(profile: profile),
           configured != profile.port, isValidPort(configured) {
            appendLog("Adopting port \(configured) from the service configuration.")
            profile.port = configured
            portError = nil
            onProfileChange?()
        }

        // Persist a preset binding discovered from live metadata so the
        // next start works from a stopped state.
        if let discovered = adapter.discoveredPresetBundle(profile: profile) {
            appendLog("Recording verified preset bundle for cold starts: "
                      + discovered.dir)
            profile.splashPreset = discovered
            onProfileChange?()
        }

        checks = adapter.setupChecks(profile: profile)
        refreshSetupStatus()
        modelChoices = await adapter.models(profile: profile)
        await refreshEndpoint()
    }

    /// Check external endpoints independently of the app's own start/stop flow.
    public func monitorEndpoint() async {
        while !Task.isCancelled {
            if !quitting { await refreshEndpoint() }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    public func refreshEndpoint() async {
        guard busy == .none, !refreshingEndpoint, !Task.isCancelled else { return }
        guard isValidPort(profile.port) else {
            portError = portRangeMessage
            status = .needsSetup(portRangeMessage)
            return
        }
        if owned?.isRunning == true { return } // owned process exit drives status
        if let owned, owned.hasExited { self.owned = nil }
        refreshingEndpoint = true
        defer { refreshingEndpoint = false }

        let checkedSession = session
        let checkedProfile = profile
        let port = checkedProfile.port
        let open = await Task.detached(priority: .utility) {
            PortInspector.isListening(port: port)
        }.value
        guard !Task.isCancelled, session == checkedSession,
              busy == .none, profile == checkedProfile else { return }

        let probe = open ? await adapter.probe(port: port, profile: checkedProfile) : .closed
        guard !Task.isCancelled, session == checkedSession,
              busy == .none, profile == checkedProfile else { return }

        let next: ServerStatus
        switch probe {
        case .closed:
            switch status {
            case .ready, .runningExternally, .portConflict:
                if managedService {
                    // Preserve ownership so an explicit Stop can retry cleanup.
                    next = .failed("The service is no longer answering on port \(port).")
                } else if let failed = checks.first(where: { !$0.ok }) {
                    next = .needsSetup("\(failed.label): \(failed.detail ?? "not found")")
                } else {
                    next = .stopped
                }
            default: return
            }
        case .provider(_, let detail, let brewService):
            if managedService {
                guard brewService else { return }
                next = .ready
            } else {
                next = .runningExternally(detail: detail ?? "Running externally",
                                          stopViaService: brewService)
            }
        case .foreign(let listeners):
            let names = listeners.map { $0.name }
            let message = "Port \(port) is already in use by "
                + (names.isEmpty ? "another process" : names.joined(separator: ", "))
            next = managedService ? .failed(message) : .portConflict(message)
        }

        guard status != next else { return }
        status = next
        lastTest = nil
        copyNote = nil
        if !isEndpointReady { launchedProfile = nil }
        // A provider becoming reachable (Start succeeded, or an external
        // server appeared on the port) means its model store may have new
        // content: refresh the list without waiting for a manual Rescan.
        if isEndpointReady { reloadModels() }
    }

    // MARK: Start

    public func start() {
        guard canStart else {
            if busy == .none && !isValidPort(profile.port) {
                portError = portRangeMessage
                status = .needsSetup(portRangeMessage)
            }
            return
        }
        portError = nil
        session += 1
        let s = session
        status = .starting
        busy = .starting
        logs.removeAll()
        copyNote = nil
        Task { await self.performStart(session: s) }
    }

    private func performStart(session s: Int) async {
        checks = adapter.setupChecks(profile: profile)
        if let failed = checks.first(where: { !$0.ok }) {
            if s == session {
                status = .needsSetup("\(failed.label): \(failed.detail ?? "not found")")
                busy = .none
            }
            return
        }

        let port = profile.port
        let open = await Task.detached(priority: .utility) {
            PortInspector.isListening(port: port)
        }.value
        if s != session { return }
        if open {
            let probe = await adapter.probe(port: port, profile: profile)
            if s != session { return }
            switch probe {
            case .closed: break
            case .provider(_, let detail, let brew):
                // Someone else already runs it: never mark it as ours to stop.
                status = .runningExternally(detail: detail ?? "Running externally",
                                            stopViaService: brew)
                busy = .none
                reloadModels()
                return
            case .foreign(let listeners):
                let names = listeners.map { $0.name }
                status = .portConflict("Port \(port) is already in use by "
                                       + (names.isEmpty ? "another process"
                                          : names.joined(separator: ", ")))
                busy = .none
                return
            }
        }

        if adapter.serviceManagedLaunch {
            appendLog("Requesting service start…")
            pendingServiceStarts.insert(s)
            let result = await adapter.startService(port: port)
            pendingServiceStarts.remove(s)
            switch result {
            case .failed(let message):
                if s == session {
                    appendLog("service start failed: \(message)")
                    status = .failed(message)
                    busy = .none
                }
                return
            case .ok:
                // From this point the service is ArcLatch's to clean up.
                managedService = true
                appendLog("Service start requested.")
            }
            if s != session {
                // Cancelled (or quit) while the start request was in flight.
                // The cancel path — or the quit path, if that fired instead
                // — is already waiting for this call to settle and owns the
                // one cleanup. Starting a second stop here would race it.
                appendLog("Service start completed after the start was "
                          + "cancelled; the pending cleanup will stop it.")
                return
            }
            await pollReady(session: s, timeout: 40, owned: nil)
            return
        }

        let plan: LaunchPlan
        do {
            plan = try adapter.launchPlan(profile: profile)
        } catch let error as LaunchPlanError {
            if s == session { status = .needsSetup(error.message); busy = .none }
            return
        } catch {
            if s == session { status = .failed(error.localizedDescription); busy = .none }
            return
        }

        let controller = ProcessController()
        controller.onLogLine = { [weak self] line in
            Task { @MainActor in self?.appendLog(line) }
        }
        controller.onExit = { [weak self] info in
            Task { @MainActor in self?.handleExit(info, session: s) }
        }
        do {
            try controller.launch(plan)
        } catch {
            appendLog("launch failed: \(error.localizedDescription)")
            if s == session {
                status = .failed("Could not launch \(plan.execURL.lastPathComponent): "
                                 + error.localizedDescription)
                busy = .none
            }
            return
        }
        if s != session {
            // Cancelled or quit between launch and ownership handoff:
            // tear the just-started process down immediately; never leak it.
            appendLog("Start was cancelled during launch; terminating the new process.")
            controller.terminate()
            Task.detached {
                if !controller.waitUntilExit(timeout: 5) { controller.forceTerminate() }
            }
            return
        }
        owned = controller
        appendLog("Started \(plan.execURL.lastPathComponent), pid \(controller.pid)")
        await pollReady(session: s, timeout: plan.readinessTimeout, owned: controller)
    }

    private func pollReady(session s: Int, timeout: TimeInterval,
                           owned controller: ProcessController?) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if s != session { return }
            if let controller, controller.hasExited { return } // handleExit sets state
            if await adapter.isReady(port: profile.port, profile: profile) {
                if s == session {
                    status = .ready
                    busy = .none
                    if controller != nil { launchedProfile = profile }
                    appendLog("Endpoint ready on port \(profile.port).")
                    // A provider that just became ready may have gained
                    // models (Ollama pulls land while stopped, etc.):
                    // refresh its model list without a manual Rescan.
                    reloadModels()
                }
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if s != session { return }
        appendLog("Timed out waiting for readiness after \(Int(timeout))s.")
        status = .failed("The server did not report ready within \(Int(timeout))s. "
                         + "See recent logs.")
        if let controller, controller.isRunning {
            controller.terminate()
            Task.detached {
                if !controller.waitUntilExit(timeout: 5) { controller.forceTerminate() }
            }
            owned = nil
        }
        if managedService {
            // Only clean up a service this start actually requested.
            Task { await self.cleanupManagedService(reason: "readiness timed out") }
        }
        busy = .none
    }

    /// An owned process that exits while this session is still current died
    /// on its own: every ArcLatch-initiated teardown (Stop, cancel, quit,
    /// readiness timeout) bumps `session` or moves the status away first.
    /// A clean exit (code 0, not signal-killed) is still a plain stop;
    /// anything else must say why, so the header shows the crash reason
    /// instead of a bare "Stopped" with the detail buried in Recent logs.
    private func handleExit(_ exit: ProcessExit, session s: Int) {
        guard s == session else { return } // late response from an old attempt
        appendLog("Process exited (status \(exit.code)).")
        owned = nil
        launchedProfile = nil
        let reason = Self.unexpectedExitReason(for: exit)
        switch status {
        case .starting:
            status = .failed(reason ?? "The process exited early (status \(exit.code)). "
                                      + "See recent logs.")
            busy = .none
        case .ready:
            if let reason {
                status = .failed(reason)
            } else {
                status = .stopped
            }
            busy = .none
        default:
            break
        }
    }

    /// Concise human reason for a process death, shown in the status line
    /// (the Recent logs disclosure below the header carries the detail).
    /// nil means the process ended cleanly: exit code 0, no signal.
    /// Signal deaths report the signal number; SIGKILL is the signature
    /// of the kernel's out-of-memory kill, so it says so.
    static func unexpectedExitReason(for exit: ProcessExit) -> String? {
        if exit.signaled {
            let oom = exit.code == 9 ? " (likely out of memory)" : ""
            return "killed by signal \(exit.code)\(oom) — open Recent logs for details"
        }
        guard exit.code != 0 else { return nil }
        return "crashed (exit code \(exit.code)) — open Recent logs for details"
    }

    // MARK: Cancel

    public func cancelStart() {
        guard status == .starting else { return }
        session += 1
        appendLog("Start cancelled.")
        if let controller = owned {
            controller.terminate()
            Task.detached {
                if !controller.waitUntilExit(timeout: 5) { controller.forceTerminate() }
            }
        }
        owned = nil
        launchedProfile = nil
        status = .stopped

        // A managed-service start can still be in flight: `brew services
        // start` may complete after the cancel and bring the service up.
        // Keep the controls busy — Start stays disabled — until that call
        // settles and any service ArcLatch started is stopped and confirmed.
        if adapter.serviceManagedLaunch,
           !pendingServiceStarts.isEmpty || managedService || serviceCleanup != nil {
            busy = .stopping
            appendLog("Cancelling a service start stops the service ArcLatch started.")
            Task { await self.settleCancelledServiceStart(reason: "start was cancelled") }
        } else {
            busy = .none
        }
    }

    /// Waits for a cancelled service start to settle, stops exactly the
    /// service ArcLatch started, and confirms it is gone before restoring
    /// the controls. If the stop fails, ownership is retained so Stop or a
    /// later quit can retry the cleanup.
    private func settleCancelledServiceStart(reason: String) async {
        let deadline = Date().addingTimeInterval(75)
        while !pendingServiceStarts.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        var ok = true
        if managedService || serviceCleanup != nil {
            ok = await cleanupManagedService(reason: reason)
            if ok { await confirmStopped() } // sets .stopped / busy on success
        }
        if busy == .stopping {
            busy = .none
            if ok {
                if status == .stopped { appendLog("Cancelled start settled.") }
            } else {
                status = .failed("The cancelled start left a service running; "
                                 + "Stop it or quit again to retry the cleanup.")
            }
        }
    }

    // MARK: Managed service

    /// Rechecks endpoint identity, then stops the service. `allowExternal`
    /// widens the guard to an explicit Stop on a verified Homebrew service
    /// that ArcLatch did not start; automatic cleanup (cancel/timeout/quit)
    /// only ever stops a service this controller started.
    private func cleanupManagedService(reason: String, allowExternal: Bool = false) async -> Bool {
        // Join an in-flight cleanup instead of racing it with a second stop.
        if let running = serviceCleanup { return await running.value }
        guard managedService || allowExternal else { return true }
        let task = Task { () -> Bool in
            let port = self.profile.port
            let label = self.adapter.managedServiceLabel

            /// A stop is finished only when the service manager agrees the
            /// agent is out of the bootstrap. Until then this controller keeps
            /// ownership, so Stop and a later quit can retry.
            @MainActor
            func stopAndSettle() async -> Bool {
                switch await self.adapter.stopService(port: port) {
                case .failed(let message):
                    self.appendLog("service stop failed: \(message)")
                    return false
                case .ok:
                    let registration = await self.adapter.serviceRegistration()
                    guard registration.blocksShutdown else {
                        self.managedService = false
                        self.appendLog("Service stop completed (\(reason)).")
                        return true
                    }
                    self.appendLog("The stop request completed, but \(label) is still "
                                   + "\(registration == .stopping ? "stopping" : "registered"); "
                                   + "ownership is kept so Stop or a later quit can retry.")
                    return false
                }
            }

            let probe = await self.adapter.probe(port: port, profile: self.profile)
            switch probe {
            case .provider(_, _, true):
                return await stopAndSettle()
            case .closed:
                // A closed port proves nothing on its own. A start that is
                // still bringing the program up leaves the service registered
                // while it listens nowhere, so the service manager's answer
                // about the agent's identity decides — never the port.
                let registration = await self.adapter.serviceRegistration()
                guard registration.blocksShutdown else {
                    self.managedService = false
                    self.appendLog("Service already stopped (\(reason)).")
                    return true
                }
                self.appendLog("Nothing answers on port \(port), but "
                               + "\(label) is still "
                               + "\(registration == .stopping ? "stopping" : "registered"); "
                               + "stopping it.")
                return await stopAndSettle()
            case .provider:
                self.managedService = false
                self.appendLog("The endpoint on port \(port) no longer looks like an "
                               + "ArcLatch-started service; leaving it running.")
                return true
            case .foreign:
                self.managedService = false
                self.appendLog("Port \(port) is now held by another process; leaving it alone.")
                return true
            }
        }
        serviceCleanup = task
        let ok = await task.value
        serviceCleanup = nil
        return ok
    }

    // MARK: Stop

    public func stop() {
        guard canStop else { return }
        session += 1
        busy = .stopping

        if let controller = owned {
            if controller.isRunning {
                appendLog("Stopping pid \(controller.pid)…")
                controller.terminate()
                Task.detached { [weak self] in
                    let exited: Bool
                    if controller.waitUntilExit(timeout: 10) {
                        exited = true
                    } else {
                        controller.forceTerminate()
                        exited = controller.waitUntilExit(timeout: 5)
                    }
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.owned = nil
                        self.launchedProfile = nil
                        if !exited {
                            self.busy = .none
                            self.status = .failed("The process would not exit.")
                        }
                    }
                    if exited { await self?.confirmStopped() }
                }
            } else {
                owned = nil
                launchedProfile = nil
                Task { await self.confirmStopped() }
            }
            return
        }

        let externalService = isViaServiceStatus()
        if managedService || externalService {
            // Stop via the service manager only after rechecking identity.
            Task {
                appendLog("Requesting service stop…")
                let ok = await cleanupManagedService(reason: "stop requested",
                                                     allowExternal: externalService)
                if ok {
                    await self.confirmStopped()
                } else {
                    self.busy = .none
                    self.status = .failed("Could not stop the service. See recent logs.")
                }
            }
            return
        }
        busy = .none
    }

    private func isViaServiceStatus() -> Bool {
        if case .runningExternally(_, let viaService) = status, viaService { return true }
        return false
    }

    /// Confirms the endpoint is actually gone before reporting stopped: the
    /// port closing is what "stopped" means for an owned process, and for a
    /// managed service the agent must also be out of the service manager's
    /// bootstrap — a registered agent with a closed port is a service that is
    /// still starting, not one that has stopped. Ownership stays in place when
    /// the confirmation fails, so Stop or a later quit retries the cleanup.
    private func confirmStopped() async {
        let port = profile.port
        let (open, registration) = await awaitEndpointGone(port: port,
                                                          managed: adapter.serviceManagedLaunch)
        if !open && !registration.blocksShutdown {
            status = .stopped
            busy = .none
            lastTest = nil
            appendLog("Stopped; port \(port) closed.")
            return
        }
        if open {
            status = .failed("Port \(port) is still open after stopping.")
        } else {
            status = .failed("\(adapter.managedServiceLabel) is still "
                + "\(registration == .stopping ? "stopping" : "registered") after stopping. "
                + "Stop this provider or quit again to retry the cleanup.")
        }
        busy = .none
    }

    /// Waits for "gone": the port closed **and**, for a managed service, the
    /// agent out of the service manager's bootstrap. Bails early once the port
    /// is closed while the manager keeps reporting the agent — waiting longer
    /// cannot change that answer, and the caller must retain ownership.
    private func awaitEndpointGone(port: Int, managed: Bool, maxTries: Int = 15) async
        -> (open: Bool, registration: ServiceRegistration) {
        var open = true
        var registration: ServiceRegistration = .notRegistered
        var closedButRegistered = 0
        for _ in 0..<maxTries {
            open = await Task.detached(priority: .utility) {
                PortInspector.isListening(port: port)
            }.value
            registration = managed ? await adapter.serviceRegistration() : .notRegistered
            if !open && !registration.blocksShutdown { return (false, registration) }
            if !open {
                closedButRegistered += 1
                if closedButRegistered >= 6 { return (false, registration) }
                try? await Task.sleep(nanoseconds: 500_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        return (open, registration)
    }

    // MARK: Quit shutdown

    /// Forced cleanup used by app quit: cancels an in-flight start, stops
    /// everything ArcLatch owns (owned process or ArcLatch-started service),
    /// and keeps ownership until exit is confirmed. Returns false when a
    /// server failed to exit, so the caller can keep the app open.
    public func shutdownForQuit() async -> Bool {
        quitting = true
        session += 1
        let port = profile.port

        // A service start that is still suspended may complete into a
        // service we own. Wait for it to settle before deciding there is
        // nothing to stop — never approve quit while it is in the air.
        let settleDeadline = Date().addingTimeInterval(75)
        while !pendingServiceStarts.isEmpty, Date() < settleDeadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if !pendingServiceStarts.isEmpty {
            appendLog("Quit: a service start is still running and did not settle; "
                      + "not quitting.")
            return false
        }

        let hadOwned = owned != nil
        let hadService = managedService
        var cleaned = true

        if let controller = owned, controller.isRunning {
            busy = .stopping
            appendLog("Quitting: stopping pid \(controller.pid)…")
            controller.terminate()
            let exited = await Task.detached(priority: .userInitiated) { () -> Bool in
                if controller.waitUntilExit(timeout: 10) { return true }
                controller.forceTerminate()
                return controller.waitUntilExit(timeout: 5)
            }.value
            if exited {
                appendLog("Quitting: process exited.")
            } else {
                cleaned = false
                appendLog("Quitting: process would not exit.")
            }
        }
        owned = nil
        launchedProfile = nil

        // Covers a service the pending start just brought up as ours.
        if managedService || serviceCleanup != nil {
            appendLog("Quitting: stopping ArcLatch-started service…")
            if !(await cleanupManagedService(reason: "app quit")) { cleaned = false }
        }

        if cleaned && (hadOwned || hadService) {
            // Confirm the endpoint this controller owned is really gone — and,
            // for a managed service, that its agent is out of the bootstrap.
            // A registered service with a closed port is still starting;
            // quitting then would leave it running under ArcLatch's name.
            let (open, registration) = await awaitEndpointGone(port: port,
                                                                managed: adapter.serviceManagedLaunch,
                                                                maxTries: 10)
            if open {
                cleaned = false
                appendLog("Quitting: port \(port) is still open.")
            } else if registration.blocksShutdown {
                cleaned = false
                appendLog("Quitting: \(adapter.managedServiceLabel) is still "
                          + "\(registration == .stopping ? "stopping" : "registered").")
            }
        }

        busy = .none
        lastTest = nil
        if !cleaned {
            status = .failed("Could not fully stop this provider.")
            // Ownership (managedService / pending state) is retained, so
            // `requiresShutdown` keeps this provider in the next quit's
            // targets. Lift the quit guard so the controls are usable: the
            // user can Stop here, or quit again to retry the cleanup.
            quitting = false
            appendLog("Quit stopped: ownership retained — Stop this provider "
                      + "or quit again to retry.")
        }
        await refreshEndpoint()
        return cleaned
    }

    // MARK: Test

    public func runTest() {
        guard canTest else { return }
        busy = .testing
        copyNote = nil
        // Test what is actually running: an owned server runs the profile it
        // was launched with, even if the selection changed while running.
        let effective = (status == .ready && owned != nil)
            ? (launchedProfile ?? profile)
            : profile
        let port = effective.port
        Task {
            let outcome = await adapter.test(port: port, profile: effective)
            if busy == .testing {
                lastTest = LastTest(outcome: outcome, date: Date())
                busy = .none
            }
        }
    }

    // MARK: Profile editing

    public func selectSplashPreset(_ choiceID: String) {
        guard id == .splash, busy == .none,
              let preset = modelChoices.first(where: { $0.id == choiceID })?.splashPreset
        else { return }
        switch status {
        case .starting, .ready, .runningExternally: return
        default: break
        }
        updateProfile {
            $0.modelID = preset.modelID
            $0.splashPreset = preset
            $0.localModelDir = nil
            $0.draftPath = nil
        }
    }

    public func updateProfile(_ mutate: (inout ProviderProfile) -> Void) {
        let old = profile
        mutate(&profile)

        // Ports are validated before they can be saved.
        if profile.port != old.port {
            if adapter.serviceManagedLaunch {
                // A managed service's port belongs to the service's own
                // configuration; saved overrides are ignored.
                profile.port = old.port
                portError = "The port comes from the service's own configuration."
            } else if isValidPort(profile.port) {
                portError = nil
            } else {
                profile.port = old.port
                portError = portRangeMessage
            }
        }

        // Bindings are bound to the model: any model change clears the
        // custom-code consent and any model-specific preset binding.
        if profile.modelID != old.modelID {
            profile.allowCustomCode = false
            profile.customCodeApprovedModel = nil
            if profile.splashPreset?.modelID != profile.modelID {
                profile.splashPreset = nil
            }
        }

        // Model or endpoint changes invalidate previous test results.
        if profile.modelID != old.modelID || profile.port != old.port
            || profile.splashPreset != old.splashPreset || profile.localModelDir != old.localModelDir
            || profile.draftPath != old.draftPath {
            lastTest = nil
            copyNote = nil
        }

        onProfileChange?()
        checks = adapter.setupChecks(profile: profile)
        refreshSetupStatus()
    }

    /// Re-evaluate the setup-derived status synchronously after the profile
    /// or checks changed. The stale-latch bug: status was only recomputed in
    /// probe/start paths, so a profile edit (model change, custom-code
    /// toggle, port fix) left header, banner, and sidebar showing the old
    /// blocker all session. Setup checks are filesystem existence checks on
    /// the profile's own paths — cheap enough for every edit, and they never
    /// walk the whole model library.
    ///
    /// Live endpoint states (.starting, .ready, .runningExternally) are left
    /// alone: the running server's reality is owned by the probe/start
    /// paths, and a stopped-state profile edit must not flip a running
    /// provider's header. With a clean setup, a stale .needsSetup clears to
    /// .stopped; if something really is listening, the endpoint monitor
    /// promotes it to ready/runningExternally on its next pass.
    private func refreshSetupStatus() {
        switch status {
        case .starting, .ready, .runningExternally: return
        default: break
        }
        guard isValidPort(profile.port) else {
            status = .needsSetup(portRangeMessage)
            return
        }
        if let failed = checks.first(where: { !$0.ok }) {
            status = .needsSetup("\(failed.label): \(failed.detail ?? "not found")")
        } else if case .needsSetup = status {
            status = .stopped
        }
    }

    /// The explicit **Rescan** action. A fresh walk of the model library runs
    /// first — bypassing the scan cache, which background refreshes keep
    /// using — so a file the user just dropped in, or just deleted, is
    /// reflected in the list at once.
    public func rescan() async {
        await Task.detached(priority: .utility) {
            _ = ModelLibrary.refresh()
        }.value
        await bootstrap()
    }

    public func reloadModels() {
        // Model listing can shell out or scan the library: run it off the
        // main thread and publish the result back when it lands.
        let adapter = self.adapter
        let scanProfile = profile
        Task {
            let fresh = await Task.detached(priority: .utility) {
                await adapter.models(profile: scanProfile)
            }.value
            modelChoices = fresh
        }
    }

    // MARK: Runtime options
    // Structured knobs (context, layers, threads, memory, tokens,
    // temperature). Values are validated before they can be saved; a
    // refused edit explains itself, exactly like an invalid port.
    // Ranges follow each engine's accepted inputs, with headroom.
    //
    // Re-commit guard: committing a value identical to the current one is
    // a no-op and must NOT clear a shown configError. Only a value that
    // actually lands clears the error, so a rejected edit stays visible
    // until the user fixes it (or clears the field to the engine default).

    public func setContextLength(_ n: Int?) {
        if let n, !(128...1_048_576).contains(n) {
            configError = "Context length must be between 128 and 1,048,576 tokens."
            return
        }
        if n != nil && n == profile.contextLength { return }
        configError = nil
        updateProfile { $0.contextLength = n }
    }

    public func setGPULayers(_ n: Int?) {
        if let n, !(0...999).contains(n) {
            configError = "GPU layers must be between 0 and 999."
            return
        }
        if n != nil && n == profile.gpuLayers { return }
        configError = nil
        updateProfile { $0.gpuLayers = n }
    }

    public func setThreadCount(_ n: Int?) {
        if let n, !(1...256).contains(n) {
            configError = "Thread count must be between 1 and 256."
            return
        }
        if n != nil && n == profile.threadCount { return }
        configError = nil
        updateProfile { $0.threadCount = n }
    }

    public func setMaxMemoryGB(_ n: Int?) {
        if let n, !(1...512).contains(n) {
            configError = "Memory budget must be between 1 and 512 GB."
            return
        }
        if n != nil && n == profile.maxMemoryGB { return }
        configError = nil
        updateProfile { $0.maxMemoryGB = n }
    }

    public func setMaxTokens(_ n: Int?) {
        if let n, !(1...131_072).contains(n) {
            configError = "Max tokens must be between 1 and 131,072."
            return
        }
        if n != nil && n == profile.maxTokens { return }
        configError = nil
        updateProfile { $0.maxTokens = n }
    }

    public func setTemperature(_ t: Double?) {
        if let t, !(0...2).contains(t) {
            configError = "Temperature must be between 0 and 2."
            return
        }
        configError = nil
        updateProfile { $0.temperature = t }
    }

    // MARK: Logs

    private func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
    }
}

// MARK: - Numeric text-field input

/// Parsing rules for the digit-only numeric fields in the UI. The old
/// `TextField(value: Int, format: .number)` fields rendered with thousands
/// separators ("8,082" for a port) and corrupted long input while editing:
/// typing 99999999 in Context length committed 899192, which passed the
/// 128…1,048,576 validation, persisted, and reached the real launch line.
/// The UI now binds these fields as strings, drops every non-digit while
/// typing, and commits the parsed Int through the validated setters.
public enum NumericInput {
    /// Keeps only ASCII digits: signs, grouping separators, spaces,
    /// currency symbols, and non-ASCII digits are all dropped.
    public static func digitsOnly(_ raw: String) -> String {
        String(raw.filter { $0 >= "0" && $0 <= "9" })
    }

    /// Parses the digit string; nil for empty (engine default) or for
    /// input too large to store as Int (overflow is rejected, not clamped).
    public static func parse(_ raw: String) -> Int? {
        let digits = digitsOnly(raw)
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }
}

// MARK: - Quit decision (shared by the app and its tests)

/// The entire quit decision in one place: the gate (which providers still
/// need shutdown, via `requiresShutdown`) and the shutdown itself. The app
/// delegate and AppState go through this, and regression tests call exactly
/// this — so a cancelled-but-still-pending service start can never slip
/// between the checks the app uses.
public enum QuitGate {
    public struct Decision: Equatable {
        public var shutdownRequested: Bool
        /// Display names of providers that failed to stop; quit must be
        /// refused while this list is non-empty.
        public var failures: [String]
    }

    @MainActor
    public static func shutdown(controllers: [ProviderController]) async -> Decision {
        let targets = controllers.filter { $0.requiresShutdown }
        guard !targets.isEmpty else {
            return Decision(shutdownRequested: false, failures: [])
        }
        var failures: [String] = []
        await withTaskGroup(of: (ProviderID, Bool).self) { group in
            for c in targets {
                let id = c.id
                group.addTask { (id, await c.shutdownForQuit()) }
            }
            for await (id, ok) in group where !ok {
                failures.append(id.displayName)
            }
        }
        return Decision(shutdownRequested: true, failures: failures)
    }
}
