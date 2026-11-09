import Testing
import Foundation
@testable import ArcLatchCore

// Recommended runtime values. Sizes and RAM always come from a stub or a
// literal: nothing here stats a real model or depends on the test machine.

private let gib: UInt64 = 1024 * 1024 * 1024

private struct StubWeights: ModelWeightSizing {
    var bytes: UInt64?
    func weightBytes(provider: ProviderID, modelID: String) -> UInt64? { bytes }
}

private final class CountingWeights: ModelWeightSizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    var bytes: UInt64?
    init(bytes: UInt64?) { self.bytes = bytes }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    func weightBytes(provider: ProviderID, modelID: String) -> UInt64? {
        lock.lock(); _calls += 1; lock.unlock()
        return bytes
    }
}

@Suite("Recommended runtime values")
struct RuntimeAdviceTests {

    @Test("The suggested context grows with the machine, never past the cache ceiling")
    func contextScalesWithRAM() {
        // 8 GB machine, 2 GB model: 16,384 tokens (2,458 MB of cache) is the
        // largest candidate inside 35% of RAM and inside weights+cache ≤ 80%.
        #expect(RuntimeAdvice.suggestedContext(weightsBytes: 2 * gib,
                                               physicalBytes: 8 * gib) == 16_384)
        #expect(RuntimeAdvice.suggestedContext(weightsBytes: 1 * gib,
                                               physicalBytes: 4 * gib) == 8_192)
        #expect(RuntimeAdvice.suggestedContext(weightsBytes: 5 * gib,
                                               physicalBytes: 16 * gib) == 32_768)
    }

    @Test("A model that already fills the machine gets no context suggestion")
    func contextRefusedWhenNothingFits() {
        // 15 GB of weights on a 16 GB machine: even the smallest candidate
        // puts weights+cache past the usable share, so the field stays empty
        // and the engine's own default wins over an invented number.
        #expect(RuntimeAdvice.suggestedContext(weightsBytes: 15 * gib,
                                               physicalBytes: 16 * gib) == nil)
        #expect(RuntimeAdvice.suggestedContext(weightsBytes: 4 * gib,
                                               physicalBytes: 0) == nil)
    }

    @Test("An unmeasurable model still gets a RAM-only context suggestion")
    func contextWithoutWeights() {
        #expect(RuntimeAdvice.suggestedContext(weightsBytes: nil,
                                               physicalBytes: 16 * gib) == 32_768)
    }

    @Test("Metal memory budget = model + cache + headroom")
    func memoryBudget() {
        let bytes = 50 * gib
        #expect(RuntimeAdvice.suggestedMemoryGB(weightsBytes: bytes,
                                                contextTokens: 32_768,
                                                physicalBytes: 128 * gib) == 69)
        // Small models still get a floor, not a 2 GB budget.
        #expect(RuntimeAdvice.suggestedMemoryGB(weightsBytes: 1 * gib,
                                                contextTokens: 2_048,
                                                physicalBytes: 16 * gib) == 8)
    }

    @Test("No memory budget when it would cap the launch below the model")
    func memoryRefusedWhenTooTight() {
        // 15 GB model, 16 GB machine: any budget in ArcLatch's range is
        // smaller than the model itself — a guaranteed out-of-memory start.
        #expect(RuntimeAdvice.suggestedMemoryGB(weightsBytes: 15 * gib,
                                                contextTokens: nil,
                                                physicalBytes: 16 * gib) == nil)
        // And never from a guess: an unmeasured model gets no number at all.
        #expect(RuntimeAdvice.suggestedMemoryGB(weightsBytes: nil,
                                                contextTokens: 4_096,
                                                physicalBytes: 128 * gib) == nil)
    }

    @Test("Ollama offers nothing to recommend")
    func ollamaHasNoKnobs() {
        let rec = RuntimeAdvice.recommend(
            provider: .ollama,
            profile: ProviderProfile(port: 11434, executablePath: "/usr/bin/true",
                                     modelID: "qwen3:8b"),
            weights: StubWeights(bytes: 8 * gib), physicalBytes: 64 * gib)
        #expect(rec.isEmpty)
        #expect(rec.note.contains("service"))
    }

    @Test("llama.cpp sets only the context; layers and threads stay auto")
    func llamaCppKeepsAutoKnobs() {
        var profile = ProviderProfile(port: 59992, executablePath: "/bin/sleep",
                                      modelID: "/private/tmp/x.gguf")
        profile.contextLength = 65_536
        let rec = RuntimeAdvice.recommend(provider: .llamacpp, profile: profile,
                                          weights: StubWeights(bytes: 5 * gib),
                                          physicalBytes: 16 * gib)
        #expect(rec.contextLength == 32_768)
        #expect(rec.gpuLayers == nil)
        #expect(rec.threadCount == nil)
        #expect(rec.note.contains("auto"))
        // The suggestion is measured from the model, not from the value that
        // happens to be saved already.
        #expect(rec.contextLength != profile.contextLength)
    }

    @Test("Splash sizes from its own preset bundle on disk")
    func splashMeasuresItsPreset() throws {
        let dir = URL(fileURLWithPath: "/private/tmp/arclatch-advice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("bundle"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Sparse file: 6 GB of recorded size without writing 6 GB.
        let bundle = dir.appendingPathComponent("bundle")
        let gguf = bundle.appendingPathComponent("model.gguf")
        FileManager.default.createFile(atPath: gguf.path, contents: Data())
        let handle = try FileHandle(forWritingTo: gguf)
        try handle.truncate(atOffset: 6 * gib)
        try handle.close()

        var profile = ProviderProfile(port: 59993, executablePath: "/bin/sleep",
                                      modelID: "org/model:Q4")
        profile.splashPreset = SplashPresetBundle(modelID: "org/model:Q4", dir: bundle.path)
        // The weight protocol reports nothing for Splash by design, so the
        // bundle measurement is the only size the advice can use.
        let rec = RuntimeAdvice.recommend(provider: .splash, profile: profile,
                                          weights: StubWeights(bytes: nil),
                                          physicalBytes: 128 * gib)
        // 6 GB + 4.8 GB cache, 25% headroom → 14 GB.
        #expect(rec.maxMemoryGB == 14)
        #expect(rec.contextLength == 32_768)
        #expect(rec.note.contains("headroom"))
    }

    @Test("A preset is measured from its manifest, not a flat folder listing")
    func splashPresetManifest() throws {
        // Real Splash bundles keep their shards in subfolders reached through
        // symlinks; a listing of the bundle folder itself finds no .gguf at
        // all, which used to leave the memory budget unsized.
        let root = URL(fileURLWithPath: "/private/tmp/arclatch-advice-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("bundle")
        let fm = FileManager.default
        try fm.createDirectory(at: bundle.appendingPathComponent("target"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("vision"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("tokenizer"),
                               withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func sparse(_ name: String, _ size: UInt64) throws {
            let url = bundle.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: Data())
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: size)
            try handle.close()
        }
        try sparse("target/model-00001-of-00002.gguf", 6 * gib)
        try sparse("target/model-00002-of-00002.gguf", 3 * gib)
        try sparse("vision/mmproj.gguf", 1 * gib)
        try sparse("tokenizer/vocab.gguf", 256 * 1024 * 1024)
        // A tokenizer GGUF counts too — the distinction is not worth a
        // second table of filename rules; what matters is that the shards do.
        let manifest = """
        {"files": {
          "target/model-00001-of-00002.gguf": {"path": "\(bundle.path)/target/model-00001-of-00002.gguf"},
          "target/model-00002-of-00002.gguf": {"path": "\(bundle.path)/target/model-00002-of-00002.gguf"},
          "vision/mmproj.gguf": {"path": "\(bundle.path)/vision/mmproj.gguf"},
          "tokenizer/vocab.gguf": {"path": "\(bundle.path)/tokenizer/vocab.gguf"},
          "config.json": {"path": "\(bundle.path)/config.json"}
        }}
        """
        fm.createFile(atPath: bundle.appendingPathComponent("model.json").path,
                      contents: Data(manifest.utf8))

        var profile = ProviderProfile(port: 59997, executablePath: "/bin/sleep",
                                      modelID: "org/model:Q4")
        profile.splashPreset = SplashPresetBundle(modelID: "org/model:Q4", dir: bundle.path)
        let rec = RuntimeAdvice.recommend(provider: .splash, profile: profile,
                                          weights: StubWeights(bytes: nil),
                                          physicalBytes: 128 * gib)
        // 10.25 GB of model + 4.8 GB of cache, 25% headroom → 19 GB.
        #expect(rec.maxMemoryGB == 19)
        #expect(rec.contextLength == 32_768)
    }

    @Test("A big preset gets no cap rather than a cap it cannot fit in")
    func splashPresetTooBigToCap() throws {
        let root = URL(fileURLWithPath: "/private/tmp/arclatch-advice-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("bundle")
        let fm = FileManager.default
        try fm.createDirectory(at: bundle.appendingPathComponent("target"),
                               withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let url = bundle.appendingPathComponent("target/big.gguf")
        fm.createFile(atPath: url.path, contents: Data())
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 79 * gib)
        try handle.close()
        fm.createFile(atPath: bundle.appendingPathComponent("model.json").path,
                      contents: Data(#"{"files": {"target/big.gguf": {"path": "\#(bundle.path)/target/big.gguf"}}}"#.utf8))

        var profile = ProviderProfile(port: 59998, executablePath: "/bin/sleep",
                                      modelID: "org/model:Q4")
        profile.splashPreset = SplashPresetBundle(modelID: "org/model:Q4", dir: bundle.path)
        let rec = RuntimeAdvice.recommend(provider: .splash, profile: profile,
                                          weights: StubWeights(bytes: nil),
                                          physicalBytes: 128 * gib)
        #expect(rec.maxMemoryGB == nil)
        #expect(rec.note.contains("needs more"))
        // The size still informs the sentence the user reads.
        #expect(rec.note.contains("Model ≈ 79 GB of 128 GB RAM"))
    }

    @Test("A Splash bundle that is gone yields no numbers, not a guess")
    func splashWithoutBundle() {
        var profile = ProviderProfile(port: 59994, executablePath: "/bin/sleep",
                                      modelID: "org/model:Q4")
        profile.splashPreset = SplashPresetBundle(modelID: "org/model:Q4",
                                                  dir: "/Volumes/not-mounted/preset")
        let rec = RuntimeAdvice.recommend(provider: .splash, profile: profile,
                                          weights: StubWeights(bytes: nil),
                                          physicalBytes: 128 * gib)
        #expect(rec.maxMemoryGB == nil)
        #expect(rec.note.contains("could not be measured"))
    }
}

@Suite("Recommended runtime values, applied")
@MainActor
struct RuntimeAdviceApplyTests {

    @Test("Use recommended sets the suggested set; engine defaults empty it")
    func applyAndClear() {
        let weights = CountingWeights(bytes: 5 * gib)
        let c = ProviderController(
            id: .llamacpp, adapter: FakeAdapter(id: .llamacpp),
            profile: ProviderProfile(port: 59995, executablePath: "/bin/sleep",
                                     modelID: "/private/tmp/x.gguf"))
        let rec = c.runtimeRecommendation(weights: weights, physicalBytes: 16 * gib)
        c.setGPULayers(20)
        c.setThreadCount(4)
        c.setContextLength(999)
        #expect(c.profile.gpuLayers == 20 && c.profile.threadCount == 4)

        c.applyRuntimeRecommendation(rec)
        #expect(c.profile.contextLength == 32_768)
        // "Leave it to the engine" is part of the recommendation: the panel
        // after the click is exactly the suggested set.
        #expect(c.profile.gpuLayers == nil)
        #expect(c.profile.threadCount == nil)
        #expect(c.configError == nil)

        c.clearRuntimeOptions()
        #expect(c.profile.contextLength == nil)
        #expect(c.profile.maxMemoryGB == nil)
        #expect(c.profile.maxTokens == nil)
        #expect(c.profile.temperature == nil)
    }

    @Test("Advice is measured once per model, not once per render")
    func adviceIsCachedPerModel() {
        let weights = CountingWeights(bytes: 5 * gib)
        let c = ProviderController(
            id: .llamacpp, adapter: FakeAdapter(id: .llamacpp),
            profile: ProviderProfile(port: 59996, executablePath: "/bin/sleep",
                                     modelID: "/private/tmp/one.gguf"))
        #expect(c.runtimeRecommendation(weights: weights, physicalBytes: 16 * gib)
                .contextLength == 32_768)
        #expect(c.runtimeRecommendation(weights: weights, physicalBytes: 16 * gib)
                .contextLength == 32_768)
        #expect(weights.calls == 1)

        // A different model means a different measurement. Knob edits must
        // not, though: they change the profile without changing the model.
        c.setContextLength(4_096)
        #expect(c.runtimeRecommendation(weights: weights, physicalBytes: 16 * gib)
                .contextLength == 32_768)
        #expect(weights.calls == 1)

        c.updateProfile { $0.modelID = "/private/tmp/two.gguf" }
        #expect(c.runtimeRecommendation(weights: weights, physicalBytes: 16 * gib)
                .contextLength == 32_768)
        #expect(weights.calls == 2)
    }
}
