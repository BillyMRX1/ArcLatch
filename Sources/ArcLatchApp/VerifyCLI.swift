import Foundation
import CoreFoundation
import ArcLatchCore

/// Headless end-to-end verification: exercises the same adapters and
/// ProviderController the UI uses, from the packaged binary. Used for the
/// integration validation pass from Terminal (normal app use never needs it).
enum VerifyCLI {
    struct Options {
        var providers: [ProviderID] = []
        var port: Int?
        var model: String?
        var exe: String?
        var allowCustomCode = false
        var extraArgs: [String] = []
        var start = false
        var test = false
        var stop = false
        var keepRunning = false
        var cancelAfter: Double?
        var cycleService = false
        var show = false
        var set = false
    }

    static func run(arguments: [String]) -> Int32 {
        var opts = Options()
        var i = 0
        let args = arguments
        while i < args.count {
            switch args[i] {
            case "--verify":
                i += 1
                if i < args.count {
                    let value = args[i]
                    if value == "all" {
                        opts.providers = ProviderID.allCases
                    } else if let id = ProviderID(rawValue: value) {
                        opts.providers = [id]
                    } else {
                        FileHandle.standardError.write(Data("unknown provider \(value)\n".utf8))
                        return 2
                    }
                }
            case "--port":
                i += 1
                guard let p = Int(args[i]), isValidPort(p) else {
                    FileHandle.standardError.write(Data(
                        "invalid port \(args[i]): \(portRangeMessage)\n".utf8))
                    return 2
                }
                opts.port = p
            case "--model": i += 1; opts.model = args[i]
            case "--exe": i += 1; opts.exe = args[i]
            case "--allow-custom-code": opts.allowCustomCode = true
            case "--extra": i += 1; opts.extraArgs = args[i].split(separator: " ").map(String.init)
            case "--start": opts.start = true
            case "--test": opts.test = true
            case "--stop": opts.stop = true
            case "--keep": opts.keepRunning = true
            case "--cancel-after": i += 1; opts.cancelAfter = Double(args[i])
            case "--cycle": opts.cycleService = true
            case "--show": opts.show = true
            case "--set": opts.set = true
            default:
                FileHandle.standardError.write(Data("unknown flag \(args[i])\n".utf8))
                return 2
            }
            i += 1
        }
        if opts.providers.isEmpty { opts.providers = [.ollama] }

        var exitCode: Int32 = 0
        Task { @MainActor in
            let store = ProfileStore()
            let loaded = await store.load()
            if opts.show {
                for id in ProviderID.allCases {
                    let p = loaded.profiles[id] ?? .defaults(for: id)
                    print("profile \(id.rawValue): port=\(p.port) exe=\(p.executablePath) "
                          + "model=\(p.modelID) customCode=\(p.allowCustomCode) "
                          + "draft=\(p.draftPath ?? "-") localDir=\(p.localModelDir ?? "-")")
                }
            }
            for id in opts.providers {
                let ok = await verifyOne(id: id, loaded: loaded, opts: opts, store: store)
                if !ok { exitCode = 1 }
            }
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopRun()
        return exitCode
    }

    @MainActor
    private static func verifyOne(id: ProviderID, loaded: ProfileStore.LoadResult,
                                  opts: Options, store: ProfileStore) async -> Bool {
        var profile = loaded.profiles[id] ?? .defaults(for: id)
        if opts.providers.count == 1 {
            if let port = opts.port { profile.port = port }
            if let model = opts.model { profile.modelID = model }
            if let exe = opts.exe { profile.executablePath = exe }
            if opts.allowCustomCode { profile.allowCustomCode = true }
            if !opts.extraArgs.isEmpty { profile.extraArgs = opts.extraArgs }
        }
        let adapter = AppState.makeAdapter(id, fake: false)
        let controller = ProviderController(id: id, adapter: adapter,
                                            profile: profile, store: store)
        print("== \(id.displayName) (port \(controller.profile.port)) ==")
        await controller.bootstrap()
        print("initial status: \(controller.status)")
        for check in controller.checks {
            print("  check \(check.ok ? "OK" : "FAIL"): \(check.label)"
                  + (check.detail.map { " — \($0)" } ?? ""))
        }
        for choice in controller.modelChoices {
            print("  model choice: \(choice.id)")
        }

        if opts.set {
            do { try await store.save([id: controller.profile]); print("saved profile.") }
            catch { print("SAVE FAIL: \(error)"); return false }
            let reloaded = await store.load()
            let round = reloaded.profiles[id] == controller.profile
            print(round ? "PERSIST OK (reloaded matches)" : "PERSIST FAIL")
            return round
        }

        var pass = true

        if let cancelAfter = opts.cancelAfter {
            controller.start()
            try? await Task.sleep(nanoseconds: UInt64(cancelAfter * 1_000_000_000))
            print("during start status: \(controller.status)")
            controller.cancelStart()
            let settled = await waitFor(timeout: 20) {
                controller.status == .stopped && !controller.isOwnedRunning
            }
            print("after cancel: status=\(controller.status) owned=\(controller.isOwnedRunning)")
            print(settled ? "CANCEL OK" : "CANCEL FAIL")
            pass = pass && settled
            return pass
        }

        if opts.start {
            controller.start()
            let settled = await waitFor(timeout: 620) {
                controller.status == .ready
                    || (controller.busy == .none && controller.status != .starting)
            }
            print("after start: status=\(controller.status) settled=\(settled)")
            if controller.status == .ready {
                print("START OK")
            } else {
                print("START NOT READY: \(controller.status)")
                pass = false
            }
            printLogs(controller)
        }

        if opts.cycleService && adapter.serviceManagedLaunch {
            controller.stop()
            let stopped = await waitFor(timeout: 30) { controller.status == .stopped }
            print("after service stop: status=\(controller.status)")
            pass = pass && stopped
            controller.start()
            let ready = await waitFor(timeout: 40) { controller.status == .ready
                || isExternal(controller.status) }
            print("after service start: status=\(controller.status)")
            pass = pass && ready
        }

        if opts.test {
            // Make sure the endpoint is usable before testing.
            if !controller.canTest { await controller.refreshEndpoint() }
            if controller.canTest {
                controller.runTest()
                let done = await waitFor(timeout: 260) {
                    controller.busy == .none && controller.lastTest != nil
                }
                if done, let last = controller.lastTest {
                    switch last.outcome {
                    case .passed(let model):
                        print("TEST PASS model=\(model ?? "?")")
                    case .failed(let message):
                        print("TEST FAIL: \(message)")
                        pass = false
                    }
                } else {
                    print("TEST FAIL: test did not finish")
                    pass = false
                }
            } else {
                print("TEST SKIP: endpoint not ready (status=\(controller.status))")
                pass = false
            }
            // Prove the copyable URL is the working endpoint.
            for entry in controller.apiURLEntries {
                guard let url = URL(string: entry.url) else { continue }
                var probe = url
                if probe.lastPathComponent == "v1" || probe.path == "/v1" {
                    probe = probe.appendingPathComponent("models")
                } else if probe.path.isEmpty || probe.path == "/" {
                    probe = probe.appendingPathComponent("api/tags")
                }
                let result = try? await URLSession.shared.data(from: probe)
                let ok = result.map { !$0.0.isEmpty } ?? false
                print("URL \(entry.url) (\(entry.label)) fetch \(ok ? "OK" : "FAIL")")
                pass = pass && ok
            }
        }

        // Cleanup only covers resources this verifier actually started. A
        // service or server that was already running when --start ran is left
        // exactly as found.
        let verifierStarted = controller.isOwnedRunning || controller.ownsManagedService
        let implicitCleanup = opts.start && !opts.keepRunning
        if opts.stop || implicitCleanup {
            if !verifierStarted && !opts.stop {
                print("cleanup: nothing was started by the verifier; leaving any "
                      + "pre-existing service running")
            } else {
                controller.stop()
                let stopped = await waitFor(timeout: 30) {
                    controller.status == .stopped
                }
                print("after stop: status=\(controller.status) owned=\(controller.isOwnedRunning)")
                print(stopped ? "STOP OK" : "STOP FAIL")
                pass = pass && stopped
            }
        }

        if opts.start && !opts.keepRunning && verifierStarted {
            // Port must be free again.
            let checkPort = controller.profile.port
            let open = await Task.detached {
                PortInspector.isListening(port: checkPort)
            }.value
            print("port \(controller.profile.port) closed after stop: \(!open)")
            pass = pass && !open
        }

        print("== \(id.displayName): \(pass ? "PASS" : "FAIL") ==")
        return pass
    }

    private static func isExternal(_ status: ServerStatus) -> Bool {
        if case .runningExternally = status { return true }
        return false
    }

    @MainActor
    private static func waitFor(timeout: TimeInterval,
                                _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return condition()
    }

    @MainActor
    private static func printLogs(_ controller: ProviderController) {
        let tail = controller.logs.suffix(12)
        if !tail.isEmpty {
            print("recent logs:")
            for line in tail { print("  " + line) }
        }
    }
}
