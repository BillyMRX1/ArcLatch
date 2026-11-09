import Foundation
import Darwin
import Dispatch

// MARK: - RAM sampling

public struct RAMSample: Equatable, Sendable {
    public var usedBytes: UInt64
    public var totalBytes: UInt64
    public init(usedBytes: UInt64, totalBytes: UInt64) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
    }
    public var fraction: Double {
        totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes)
    }
}

public protocol MemorySamplerProtocol: Sendable {
    func sample() -> RAMSample?
}

/// Reads the kernel VM statistics the same way Activity Monitor does:
/// Memory Used = App Memory (active + inactive − purgeable) + Wired + Compressed.
/// Speculative and truly free pages do not count as used.
public struct SystemMemorySampler: MemorySamplerProtocol {
    public init() {}

    public func sample() -> RAMSample? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        let page = UInt64(pageSize)
        guard page > 0 else { return nil }

        let wired = UInt64(stats.wire_count)
        let compressed = UInt64(stats.compressor_page_count)

        // App Memory should exclude reclaimable file cache. The kernel's
        // internal (anonymous) page count is exactly "pages with no file
        // copy"; the older active+inactive−purgeable formula over-counted
        // file-backed pages (~12 GB observed as "File-backed pages").
        let internalPages = UInt64(stats.internal_page_count)
        let app: UInt64
        if internalPages > 0 {
            app = internalPages
        } else {
            let active = UInt64(stats.active_count)
            let inactive = UInt64(stats.inactive_count)
            let purgeable = UInt64(stats.purgeable_count)
            app = active + inactive > purgeable ? active + inactive - purgeable : 0
        }
        let used = app + wired + compressed
        return RAMSample(usedBytes: used * page,
                         totalBytes: ProcessInfo.processInfo.physicalMemory)
    }
}

/// Deterministic sampler for previews and tests.
public struct FakeMemorySampler: MemorySamplerProtocol {
    public var totalBytes: UInt64
    private var tick: Int
    public init(totalBytes: UInt64 = 64 * 1024 * 1024 * 1024, startTick: Int = 0) {
        self.totalBytes = totalBytes
        self.tick = startTick
    }
    public func sample() -> RAMSample? {
        // Ramp gently so the meter visibly moves in previews.
        let used = totalBytes / 4 + UInt64(tick % 10) * (totalBytes / 100)
        return RAMSample(usedBytes: used, totalBytes: totalBytes)
    }
}

// MARK: - Pressure

public enum PressureState: Sendable, Equatable {
    case unknown
    case normal
    case elevated
    case high

    public var label: String {
        switch self {
        case .unknown: return "Unavailable"
        case .normal: return "Normal"
        case .elevated: return "Elevated"
        case .high: return "High"
        }
    }
}

/// System memory pressure, read from the kernel's own pressure level
/// (`kern.memorystatus_vm_pressure_level`) and pushed by Dispatch
/// memory-pressure events. The UI shows "Unavailable" until a real reading
/// exists — never a guess. Pressure is independent of used RAM percentage.
public final class PressureMonitor: @unchecked Sendable {
    private var source: DispatchSourceMemoryPressure?
    private var pollTimer: DispatchSourceTimer?
    public private(set) var state: PressureState = .unknown
    private let lock = NSLock()

    public init() {}

    /// The kernel's current system-wide pressure level: 1 = normal,
    /// 2 = warning. Nil when the sysctl is unavailable.
    public static func kernelPressureLevel() -> PressureState? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level",
                           &level, &size, nil, 0) == 0 else { return nil }
        switch level {
        case 1: return .normal
        case 2: return .elevated
        default: return nil
        }
    }

    /// Starts with the kernel's current reading (immediate, reliable), then
    /// follows Dispatch events and a slow poll. If no reading is available,
    /// the state stays .unknown so the UI shows "Unavailable".
    public func start(onChange: @escaping @Sendable (PressureState) -> Void) {
        apply(Self.kernelPressureLevel(), onChange: onChange)

        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let data = src.data
            var next: PressureState = .normal
            if data.contains(.critical) { next = .high }
            else if data.contains(.warning) { next = .elevated }
            self.apply(next, onChange: onChange)
        }
        src.resume()
        source = src

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.apply(Self.kernelPressureLevel(), onChange: onChange)
        }
        timer.resume()
        pollTimer = timer
    }

    private func apply(_ next: PressureState?, onChange: @escaping @Sendable (PressureState) -> Void) {
        guard let next else { return }
        lock.lock()
        let changed = state != next
        state = next
        lock.unlock()
        if changed { onChange(next) }
    }

    public func stop() {
        source?.cancel()
        source = nil
        pollTimer?.cancel()
        pollTimer = nil
        lock.lock(); state = .unknown; lock.unlock()
    }

    public var currentState: PressureState {
        lock.lock(); defer { lock.unlock() }
        return state
    }
}

// MARK: - Formatting

public enum RAMFormat {
    public static func gib(_ bytes: UInt64) -> String {
        let v = Double(bytes) / 1073741824.0
        if v >= 10 { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }

    public static func usedOverTotal(_ sample: RAMSample) -> String {
        "\(gib(sample.usedBytes)) / \(gib(sample.totalBytes)) GB"
    }
}

// MARK: - Free RAM sampling

/// "How much room is there right now?" — the free side of a start-time fit
/// check. Injectable so tests stub it: nothing in the test target touches
/// mach directly.
public protocol FreeMemorySampling: Sendable {
    func freeBytes() -> UInt64?
}

/// Reads the same vm_statistics64 the used-RAM sampler uses: truly free
/// pages plus pages the kernel already knows are purgeable. Deliberately
/// excludes inactive/file-backed pages — those need eviction before they
/// are usable, and a "will this fit" figure should not count eviction as
/// instant space. Underestimating free space is the safe direction: it can
/// warn "may not fit", never promise a fit that swapping then betrays.
public struct SystemFreeMemory: FreeMemorySampling {
    public init() {}

    public func freeBytes() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)
        let page = UInt64(pageSize)
        guard page > 0 else { return nil }
        return (UInt64(stats.free_count) + UInt64(stats.purgeable_count)) * page
    }
}

/// Deterministic free-memory figure for previews and fake mode.
public struct FakeFreeMemorySampling: FreeMemorySampling {
    public var totalBytes: UInt64
    public init(totalBytes: UInt64 = 64 * 1024 * 1024 * 1024) {
        self.totalBytes = totalBytes
    }
    public func freeBytes() -> UInt64? { totalBytes / 2 }
}

// MARK: - Model weight sizing

/// Total bytes of weight files a start would load, per provider. Injectable
/// so tests stub the filesystem entirely; the real implementation only
/// stats paths from the profile (never walks the whole library).
public protocol ModelWeightSizing: Sendable {
    /// nil when the provider serves from an internal store (Ollama, Splash)
    /// or the model's files cannot be measured: no estimate beats a wrong
    /// estimate.
    func weightBytes(provider: ProviderID, modelID: String) -> UInt64?
}

public struct FileSystemModelWeights: ModelWeightSizing {
    public init() {}

    public func weightBytes(provider: ProviderID, modelID: String) -> UInt64? {
        let fm = FileManager.default
        switch provider {
        case .ollama, .splash:
            // External stores (Ollama's blob store, Splash's installed
            // presets): ArcLatch cannot attribute a size to the served
            // model, so show nothing rather than a guessed number.
            return nil
        case .llamacpp:
            var isDir: ObjCBool = false
            guard modelID.hasSuffix(".gguf"),
                  fm.fileExists(atPath: modelID, isDirectory: &isDir),
                  !isDir.boolValue else { return nil }
            // Split GGUFs: the profile carries the first shard, and llama.cpp
            // opens the siblings itself; this figures the listed file only.
            return fileSize(of: modelID)
        case .mlxlm:
            guard ModelLibrary.isMLXModelFolder(modelID),
                  let names = try? fm.contentsOfDirectory(atPath: modelID)
            else { return nil }
            var total: UInt64 = 0
            var any = false
            for name in names where name.lowercased().hasSuffix(".safetensors") {
                if let size = fileSize(of: modelID + "/" + name) {
                    total += size
                    any = true
                }
            }
            return any ? total : nil
        }
    }

    private func fileSize(of path: String) -> UInt64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.size] as? UInt64
    }
}

// MARK: - Start-time fit estimate

/// "Will this fit?" next to the Start button: model weights plus a rough
/// KV allowance against currently free RAM. Soft guidance only — the
/// server knows its own business better than this figure does.
public struct StartMemoryEstimate: Equatable, Sendable {
    public var weightsBytes: UInt64
    public var kvBytes: UInt64
    public var availableBytes: UInt64

    public init(weightsBytes: UInt64, kvBytes: UInt64, availableBytes: UInt64) {
        self.weightsBytes = weightsBytes
        self.kvBytes = kvBytes
        self.availableBytes = availableBytes
    }

    public var requiredBytes: UInt64 { weightsBytes + kvBytes }
    public var fits: Bool { requiredBytes <= availableBytes }

    public var caption: String {
        let base = "Model ≈ \(RAMFormat.gib(weightsBytes)) GB · "
            + "~\(RAMFormat.gib(availableBytes)) GB free"
        return fits ? base : base + " — may not fit"
    }
}

public enum StartMemoryCheck {
    /// KV allowance reuses the single documented heuristic constant from
    /// RAMSanity (0.15 MB/token) — one source, two call sites.
    /// With no context length set, the engine default is unknown, so the
    /// documented conventional llama.cpp default is assumed.
    public static let defaultContextTokens = 4096

    public static func kvBytes(contextLength: Int?) -> UInt64 {
        let ctx = contextLength ?? defaultContextTokens
        guard ctx > 0 else { return 0 }
        return UInt64((Double(ctx) * RAMSanity.kvMBPerToken * 1_048_576).rounded())
    }

    /// nil whenever any input is unmeasurable (external-store provider,
    /// missing model file, no RAM reading).
    public static func estimate(
        provider: ProviderID,
        profile: ProviderProfile,
        weights: any ModelWeightSizing = FileSystemModelWeights(),
        free: any FreeMemorySampling = SystemFreeMemory()
    ) -> StartMemoryEstimate? {
        guard let weightsBytes = weights.weightBytes(provider: provider,
                                                     modelID: profile.modelID)
        else { return nil }
        guard let availableBytes = free.freeBytes(), availableBytes > 0 else { return nil }
        return StartMemoryEstimate(weightsBytes: weightsBytes,
                                   kvBytes: kvBytes(contextLength: profile.contextLength),
                                   availableBytes: availableBytes)
    }
}

// MARK: - Context-length sanity estimate

/// Soft caution for absurd context lengths (never a hard block; the range
/// validation in the coordinator remains the gate). One documented linear
/// heuristic: estimate the KV cache at ~0.15 MB per token — a mid-size
/// transformer's fp16 cache, roughly 150 GB per million tokens — and warn
/// when that estimate alone exceeds half of physical RAM, since the model
/// weights and activations must live in the rest.
public enum RAMSanity {
    /// Rough KV-cache cost per token, in MB (fp16 K+V for a typical
    /// mid-size model; llama.cpp-style cache).
    public static let kvMBPerToken = 0.15
    /// Warn when the KV estimate alone passes this fraction of RAM.
    public static let ramFraction = 0.5

    public static func warning(contextLength: Int,
                               physicalMemoryBytes: UInt64) -> String? {
        guard physicalMemoryBytes > 0, contextLength > 0 else { return nil }
        let estimatedKVMB = Double(contextLength) * kvMBPerToken
        let availableMB = Double(physicalMemoryBytes) / 1_048_576.0
        guard estimatedKVMB > availableMB * ramFraction else { return nil }
        return "\(grouped(contextLength)) tokens will likely exceed available RAM "
            + "(~\(RAMFormat.gib(physicalMemoryBytes)) GB)."
    }

    /// Locale-independent thousands grouping for the token count ("899,192"),
    /// matching how the app formats token numbers elsewhere.
    static func grouped(_ n: Int) -> String {
        let digits = String(n)
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return out
    }
}
