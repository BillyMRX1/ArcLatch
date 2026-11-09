import Foundation

// MARK: - Recommended runtime values
//
// The runtime knobs start empty, which means "use whatever the engine
// defaults to" — correct, but not very helpful to someone who just wants a
// reasonable number. This computes one from the machine and the model that
// are actually in front of us, and offers it as a suggestion the user can
// take or leave: every field can still be cleared back to the engine's own
// default, and each value still goes through the same validated setters as a
// hand-typed one.

public struct RuntimeRecommendation: Equatable, Sendable {
    public var contextLength: Int?
    public var gpuLayers: Int?
    public var threadCount: Int?
    public var maxMemoryGB: Int?
    public var maxTokens: Int?
    public var temperature: Double?
    /// Plain-language reason for the numbers, shown next to the buttons.
    public var note: String

    public init(contextLength: Int? = nil, gpuLayers: Int? = nil,
                threadCount: Int? = nil, maxMemoryGB: Int? = nil,
                maxTokens: Int? = nil, temperature: Double? = nil,
                note: String = "") {
        self.contextLength = contextLength
        self.gpuLayers = gpuLayers
        self.threadCount = threadCount
        self.maxMemoryGB = maxMemoryGB
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.note = note
    }

    /// True when there is nothing to offer (Ollama: its knobs belong to the
    /// service configuration, not to a start).
    public var isEmpty: Bool {
        contextLength == nil && gpuLayers == nil && threadCount == nil
            && maxMemoryGB == nil && maxTokens == nil && temperature == nil
    }
}

public enum RuntimeAdvice {
    /// Token counts worth suggesting, largest first. Powers of two because
    /// that is what people type and what engines quantize to.
    public static let contextCandidates = [32_768, 16_384, 8_192, 4_096, 2_048]

    /// Ceiling on what the KV cache alone may take of physical RAM.
    public static let kvRAMFraction = 0.35
    /// Ceiling on weights + KV together.
    public static let totalRAMFraction = 0.8
    /// Splash's Metal memory budget gets this much headroom over the model
    /// plus its KV allowance, and never more than this share of the machine.
    public static let memoryHeadroom = 1.25
    public static let memoryRAMFraction = 0.75

    /// All sizes come from injectable sources so tests never touch a disk.
    public static func recommend(
        provider: ProviderID,
        profile: ProviderProfile,
        weights: any ModelWeightSizing = FileSystemModelWeights(),
        physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> RuntimeRecommendation {
        let modelBytes = measuredWeights(provider: provider, profile: profile,
                                         weights: weights)
        let context = suggestedContext(weightsBytes: modelBytes,
                                       physicalBytes: physicalBytes)
        switch provider {
        case .ollama:
            return RuntimeRecommendation(note: "Ollama has no per-start knobs to "
                + "recommend: its runtime options live in the service's own "
                + "environment, which ArcLatch never rewrites.")

        case .llamacpp:
            // GPU layers and threads stay empty on purpose. Verified against
            // the installed build's own help: `-ngl` defaults to auto, which
            // offloads as many layers as fit and is smarter than a fixed
            // count, and `-t` defaults to auto as well. The context length is
            // the one worth setting: `-c` defaults to 0 = the model's native
            // size, and a 4096-context model and a 262144-context one get
            // wildly different KV caches from that.
            var rec = RuntimeRecommendation(contextLength: context)
            rec.note = noteText(context: context, weightsBytes: modelBytes,
                                physicalBytes: physicalBytes,
                                extra: "GPU layers and CPU threads stay on auto — "
                                + "this llama.cpp sizes both better than a fixed "
                                + "number would.")
            return rec

        case .splash:
            let memory = suggestedMemoryGB(weightsBytes: modelBytes,
                                           contextTokens: context,
                                           physicalBytes: physicalBytes)
            var rec = RuntimeRecommendation(contextLength: context, maxMemoryGB: memory)
            rec.note = noteText(context: context, weightsBytes: modelBytes,
                                physicalBytes: physicalBytes,
                                extra: memoryNote(weightsBytes: modelBytes, offered: memory))
            return rec

        case .mlxlm:
            var rec = RuntimeRecommendation(maxTokens: 1_024, temperature: 0.7)
            rec.note = "1,024 tokens per reply and temperature 0.7 suit chat use; "
                + "leave a field empty to take mlx_lm.server's own default."
            return rec
        }
    }

    // MARK: Rules

    /// The largest candidate whose KV cache stays inside its share of RAM and
    /// which, together with the weights, still fits in the usable share. nil
    /// means nothing sensible fits: better to leave it to the engine than to
    /// invent a number.
    public static func suggestedContext(weightsBytes: UInt64?,
                                        physicalBytes: UInt64) -> Int? {
        guard physicalBytes > 0 else { return nil }
        let ramMB = Double(physicalBytes) / 1_048_576
        for tokens in contextCandidates {
            // One documented heuristic, shared with the fit caption and the
            // context sanity warning (see RAMSanity.kvMBPerToken).
            let kvMB = Double(tokens) * RAMSanity.kvMBPerToken
            guard kvMB <= ramMB * kvRAMFraction else { continue }
            if let weightsBytes {
                let weightsMB = Double(weightsBytes) / 1_048_576
                guard weightsMB + kvMB <= ramMB * totalRAMFraction else { continue }
            }
            return tokens
        }
        return nil
    }

    /// Splash's `--max-memory`: model plus cache, plus headroom — and only
    /// when that fits inside a sane share of the machine. A cap smaller than
    /// the model needs is worse than no cap: it turns a start that would have
    /// worked into an out-of-memory failure. So when the model is larger than
    /// the ceiling, or its size cannot be measured at all, nothing is
    /// suggested and Splash keeps its own default.
    public static func suggestedMemoryGB(weightsBytes: UInt64?,
                                         contextTokens: Int?,
                                         physicalBytes: UInt64) -> Int? {
        guard physicalBytes > 0, let weightsBytes, weightsBytes > 0 else { return nil }
        let ramGB = Double(physicalBytes) / 1_073_741_824
        let tokens = contextTokens ?? StartMemoryCheck.defaultContextTokens
        let kvGB = Double(tokens) * RAMSanity.kvMBPerToken / 1_024
        let weightsGB = Double(weightsBytes) / 1_073_741_824
        let needed = (weightsGB + kvGB) * memoryHeadroom
        guard needed <= ramGB * memoryRAMFraction else { return nil }
        return Swift.max(8, Int(needed.rounded(.up)))
    }

    /// Why there is or is not a memory number to offer.
    private static func memoryNote(weightsBytes: UInt64?, offered: Int?) -> String? {
        if offered != nil {
            return "Metal memory budget sized for the model and its cache, "
                + "with headroom."
        }
        if weightsBytes == nil {
            return "No Metal memory budget is suggested: the model's files could "
                + "not be measured, and a guess could cap the launch below what "
                + "the model needs."
        }
        return "No Metal memory budget is suggested: the model alone needs more "
            + "than the share of RAM ArcLatch would budget, so Splash's own "
            + "default is the safer choice."
    }

    // MARK: Weights

    /// Ollama and Splash serve from stores ArcLatch does not own, so
    /// `FileSystemModelWeights` deliberately reports nothing for them. For
    /// Splash there is usually something better on disk: the preset bundle's
    /// own manifest, or the local folder the user pointed at. Measuring those
    /// beats sizing a memory budget from RAM alone — and the sizes involved
    /// are large enough that getting them wrong is the difference between a
    /// workable cap and one that guarantees a failed launch.
    static func measuredWeights(provider: ProviderID,
                                profile: ProviderProfile,
                                weights: any ModelWeightSizing) -> UInt64? {
        if let direct = weights.weightBytes(provider: provider, modelID: profile.modelID) {
            return direct
        }
        guard provider == .splash else { return nil }
        // Bundle first: a resolved preset keeps its GGUFs in subfolders
        // (target/, vision/, draft/) reached through symlinks, so a flat
        // listing of the bundle folder finds nothing. The manifest Splash
        // wrote lists every file it will load, with absolute paths.
        let dirs = [profile.splashPreset?.dir, profile.localModelDir].compactMap { $0 }
        for dir in dirs where ModelLibrary.isDirectory(dir) {
            if let manifest = SplashAdapter.manifest(dir: dir),
               let files = SplashAdapter.manifestFiles(manifest) {
                let total = sumSizes(files.map { $0.path }.filter { isWeightFile($0) })
                if total > 0 { return total }
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            let total = sumSizes(names.map { dir + "/" + $0 }.filter { isWeightFile($0) })
            if total > 0 { return total }
        }
        return nil
    }

    /// Model files a Splash start maps into Metal: the target shards, the
    /// vision projector, the draft. Tokenizer and config files cost nothing
    /// comparable, so they are left out.
    private static func isWeightFile(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".gguf") || path.lowercased().hasSuffix(".safetensors")
    }

    private static func sumSizes(_ paths: [String]) -> UInt64 {
        let fm = FileManager.default
        var total: UInt64 = 0
        for path in paths {
            // attributesOfItem follows the bundle's symlinks, which is the
            // size the server will actually read.
            if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? UInt64 {
                total += size
            }
        }
        return total
    }

    // MARK: Wording

    private static func noteText(context: Int?, weightsBytes: UInt64?,
                                 physicalBytes: UInt64, extra: String?) -> String {
        var parts: [String] = []
        if let context {
            let kvGB = Double(context) * RAMSanity.kvMBPerToken / 1_024
            parts.append("Context \(RAMSanity.grouped(context)) tokens "
                + "(≈\(String(format: "%.1f", kvGB)) GB of cache).")
        } else {
            parts.append("No context length fits this machine's free memory "
                + "comfortably: leaving it empty uses the engine's default.")
        }
        if let weightsBytes {
            parts.append("Model ≈ \(RAMFormat.gib(weightsBytes)) GB of "
                + "\(RAMFormat.gib(physicalBytes)) GB RAM.")
        }
        if let extra { parts.append(extra) }
        parts.append("Empty field = engine default.")
        return parts.joined(separator: " ")
    }
}
