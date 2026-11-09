import Foundation

/// Why a launched program ended, as the coordinator needs to explain it:
/// `code` is the process's exit code, or the signal number when `signaled`
/// is true (the process was killed — e.g. SIGKILL from an out-of-memory
/// kill — rather than exiting on its own).
public struct ProcessExit: Equatable, Sendable {
    public var code: Int32
    public var signaled: Bool
    public init(code: Int32, signaled: Bool) {
        self.code = code
        self.signaled = signaled
    }
}

/// Owns one launched program: absolute executable URL + argument array,
/// never a shell string. Captures both streams without blocking the UI and
/// exposes termination primitives.
public final class ProcessController: @unchecked Sendable {
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let stateLock = NSLock()
    private var exited = false
    private var exitStatus: Int32 = 0
    private let exitSemaphore = DispatchSemaphore(value: 0)
    private let logQueue = DispatchQueue(label: "arclatch.process.logs")

    public var onLogLine: (@Sendable (String) -> Void)?
    public var onExit: (@Sendable (ProcessExit) -> Void)?

    public private(set) var pid: Int32 = 0

    public init() {}

    public func launch(_ plan: LaunchPlan) throws {
        process.executableURL = plan.execURL
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = plan.workingDirectory
        process.standardOutput = outPipe
        process.standardError = errPipe

        attachReader(outPipe.fileHandleForReading, tag: "out")
        attachReader(errPipe.fileHandleForReading, tag: "err")

        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            let info = ProcessExit(code: p.terminationStatus,
                                   signaled: p.terminationReason == .uncaughtSignal)
            self.stateLock.lock()
            self.exited = true
            self.exitStatus = info.code
            self.stateLock.unlock()
            self.exitSemaphore.signal()
            DispatchQueue.main.async { self.onExit?(info) }
        }

        try process.run()
        pid = process.processIdentifier
    }

    private func attachReader(_ handle: FileHandle, tag: String) {
        handle.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                return
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let trimmed = String(line).prefix(600)
                self?.logQueue.async {
                    let cb = self?.onLogLine
                    cb?("[\(tag)] \(trimmed)")
                }
            }
        }
    }

    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return !exited && process.isRunning
    }

    /// The engine's normal shutdown signal.
    public func terminate() {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
    }

    public func forceTerminate() {
        guard pid > 0 else { return }
        kill(pid, SIGKILL)
    }

    @discardableResult
    public func waitUntilExit(timeout: TimeInterval) -> Bool {
        exitSemaphore.wait(timeout: .now() + timeout) == .success
    }

    public var hasExited: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return exited
    }
}

/// Short synchronous helper for tool invocations like `brew services …`
/// or `lsof`. Direct binary + argument array; no shell.
public enum ToolRunner {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    public static func run(_ path: String, _ args: [String],
                           timeout: TimeInterval = 30,
                           environment: [String: String]? = nil) -> Result {
        let p = Process()
        let out = Pipe(); let err = Pipe()
        var gatheredOut = Data(); var gatheredErr = Data()
        let group = DispatchQueue(label: "arclatch.tool")
        do {
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardOutput = out
            p.standardError = err
            if let environment { p.environment = environment }
            try p.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: "\(error.localizedDescription)")
        }
        let done = DispatchSemaphore(value: 0)
        group.async {
            gatheredOut = out.fileHandleForReading.readDataToEndOfFile()
            gatheredErr = err.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        let finished = done.wait(timeout: .now() + timeout) == .success
        if !finished {
            p.terminationHandler = nil
            kill(p.processIdentifier, SIGKILL)
            p.waitUntilExit()
            return Result(status: -1,
                          stdout: String(data: gatheredOut, encoding: .utf8) ?? "",
                          stderr: "timed out after \(Int(timeout))s")
        }
        p.waitUntilExit()
        return Result(
            status: p.terminationStatus,
            stdout: String(data: gatheredOut, encoding: .utf8) ?? "",
            stderr: String(data: gatheredErr, encoding: .utf8) ?? "")
    }
}
