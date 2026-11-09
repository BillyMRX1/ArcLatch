import SwiftUI
import AppKit
import ArcLatchCore

// MARK: - Digit-only numeric field
//
// The old `TextField(value: Int, format: .number)` fields displayed
// grouping separators ("8,082" for a port) and corrupted long input while
// editing: typing 99999999 in Context length committed 899192, which passed
// range validation, persisted to profiles.json, and reached the real
// llama-server launch line. Every numeric field is now backed by a plain
// text field that accepts digits only (separators, signs, spaces, and any
// other character are dropped as typed) and commits the parsed value on
// Return or when focus leaves. Committing the unchanged value is not an
// edit — a shown configError survives it — and on focus loss the field
// re-displays the stored value, with the error line explaining any refusal.
// This is an NSViewRepresentable because this toolchain has no SwiftUI
// macro plugin: no @State/@FocusState (see AppState.swift for the same
// constraint on the observation side).

struct DigitField: NSViewRepresentable {
    let title: String
    var placeholder: String = ""
    var width: CGFloat = 110
    let value: Int?
    var enabled: Bool = true
    /// Receives (parsed, sanitizedDigits) on commit. Sanitized digits
    /// empty = commit the engine default (nil); parsed nil with non-empty
    /// digits = overflow too large to store (the caller reports it).
    let commit: (_ parsed: Int?, _ sanitizedDigits: String) -> Void

    private static func display(_ value: Int?) -> String {
        value.map(String.init) ?? ""
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = DigitNSTextField()
        field.preferredWidth = width
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commitAction(_:))
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let text = Self.display(value)
        field.stringValue = text
        context.coordinator.lastCommitted = text
        field.setAccessibilityLabel(title)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = enabled
        field.placeholderString = placeholder
        field.setAccessibilityLabel(title)
        // Re-sync to the stored value only while not editing; the AppKit
        // bridge rebuilds the whole tree on every published change (the RAM
        // strip ticks every 2s), and typing must not be clobbered by that.
        if field.currentEditor() == nil {
            let wanted = Self.display(value)
            if field.stringValue != wanted {
                field.stringValue = wanted
                context.coordinator.lastCommitted = wanted
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: DigitField
        /// The text the last commit stored; re-presenting it is not an edit.
        var lastCommitted: String = ""
        init(_ parent: DigitField) { self.parent = parent }

        // Drop non-digits as they are typed: grouping separators, signs,
        // spaces, and any other character never remain in the field.
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let clean = NumericInput.digitsOnly(field.stringValue)
            if clean != field.stringValue { field.stringValue = clean }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            commit(field)
        }

        @objc func commitAction(_ sender: NSTextField) { commit(sender) }

        private func commit(_ field: NSTextField) {
            let raw = NumericInput.digitsOnly(field.stringValue)
            guard raw != lastCommitted else { return }
            lastCommitted = raw
            parent.commit(NumericInput.parse(raw), raw)
        }
    }
}

/// Fixed-width NSTextField: SwiftUI lays out representables by intrinsic
/// content size, so the field must keep its width as the text changes.
private final class DigitNSTextField: NSTextField {
    var preferredWidth: CGFloat = 110
    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: 21)
    }
}

struct DetailView: View {
    let state: AppState
    let revision: Int

    var body: some View {
        Group {
            if let controller = state.controller(state.selected) {
                ProviderDetail(state: state, controller: controller, revision: revision)
            } else {
                ProgressView("Loading providers…")
            }
        }
        .padding(18)
    }
}

struct ProviderDetail: View {
    let state: AppState
    let controller: ProviderController
    let revision: Int

    private var isRunningLike: Bool {
        controller.status == .ready || controller.status == .starting
            || isExternal(controller.status)
    }
    /// Launch-bound model controls are locked while a server is starting or
    // running, so the selection can never drift from the served model.
    // Ollama keeps its tag picker live: one server serves many tags, and the
    // choice only affects the next request.
    private var modelLocked: Bool {
        controller.status == .starting || controller.busy == .starting
            || (isRunningLike && controller.id != .ollama)
    }
    private func isExternal(_ s: ServerStatus) -> Bool {
        if case .runningExternally = s { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    providerResources
                }
                modelSection
                // While the Ollama store appears empty, the saved tag's
                // caption is misleading: it names a tag the store has not
                // listed, and refreshes as soon as tags come back.
                if !(controller.id == .ollama && controller.modelChoices.isEmpty) {
                    pathLine
                }

                if !controller.checks.filter({ !$0.ok }).isEmpty || needsSetupNotice {
                    setupIssues
                }

                advancedSection
                actionsRow
                resultSection

                if let note = state.storeNote {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .quaternaryLabelColor)))
                }
                if let note = state.quitNote {
                    Label(note, systemImage: "exclamationmark.octagon.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .quaternaryLabelColor)))
                }
            }
            .padding(.trailing, 6)
        }
    }

    private var needsSetupNotice: Bool {
        if case .needsSetup = controller.status { return true }
        return false
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text(controller.id.displayName)
                .font(.title2.weight(.semibold))
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(StatusStyle.color(for: controller.status))
                    .frame(width: 8, height: 8)
                Text(controller.detailStatusText)
                    .font(.callout)
                    .foregroundStyle(StatusStyle.color(for: controller.status))
                    .multilineTextAlignment(.trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(controller.detailStatusText)")
        }
    }

    private var providerResources: some View {
        HStack(spacing: 14) {
            ForEach(resourceLinks, id: \.address) { resource in
                if let url = URL(string: resource.address) {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Text(resource.title)
                            Image(systemName: "arrow.up.right")
                                .accessibilityHidden(true)
                        }
                    }
                    .help(url.absoluteString)
                }
            }
        }
        .font(.callout)
    }

    private var resourceLinks: [(title: String, address: String)] {
        switch controller.id {
        case .ollama:
            return [
                ("Model library", "https://ollama.com/library"),
                ("Quickstart", "https://docs.ollama.com/quickstart"),
            ]
        case .splash:
            return [
                ("Supported models", "https://github.com/incoai/splash#models"),
                ("Local model setup", "https://github.com/incoai/splash/blob/main/docs/models.md#local-model-files"),
            ]
        case .mlxlm:
            return [
                ("MLX model catalog", "https://huggingface.co/mlx-community"),
                ("MLX-LM quickstart", "https://github.com/ml-explore/mlx-lm#quick-start"),
            ]
        case .llamacpp:
            return [
                ("GGUF model catalog", "https://huggingface.co/models?library=gguf"),
                ("Server documentation", "https://github.com/ggml-org/llama.cpp/tree/master/tools/server"),
            ]
        }
    }

    // MARK: Model

    @ViewBuilder private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model").font(.headline)

            if controller.id == .ollama {
                if controller.modelChoices.count > 1 {
                    Picker("Model", selection: modelSelectionBinding) {
                        ForEach(controller.modelChoices) { choice in
                            Text(choice.label).tag(choice.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(modelLocked)
                    .frame(maxWidth: 420, alignment: .leading)
                } else if let only = controller.modelChoices.first {
                    Text(only.label)
                } else {
                    // Condensed stopped-state copy: one sentence instead of
                    // three near-duplicates.
                    Text("No tags in the Ollama store — start the service to list them.")
                        .foregroundStyle(.secondary)
                }
                if !controller.modelChoices.isEmpty {
                    Text("Ollama manages its own model store.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if controller.id == .splash {
                splashModelPicker
            } else if controller.modelChoices.count > 1 {
                Picker("Model", selection: modelSelectionBinding) {
                    ForEach(controller.modelChoices) { choice in
                        Text(choice.label).tag(choice.id)
                    }
                }
                .labelsHidden()
                .disabled(modelLocked)
                .frame(maxWidth: 420, alignment: .leading)
            } else if let only = controller.modelChoices.first {
                Text(only.label)
                if let detail = only.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if controller.id == .llamacpp || controller.id == .mlxlm,
                      state.modelsDirectory.isEmpty || libraryBlocked() {
                // Empty here means the folder is missing or unreadable, not
                // that it holds nothing: say which, and put the way out next
                // to the words rather than buried in a banner.
                Text(state.modelsDirectory.isEmpty
                     ? "No model folder chosen. ArcLatch does not walk the whole "
                       + "home folder on its own."
                     : "The model folder “\(shortUserPath(state.modelsDirectory))” "
                       + "cannot be read.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No local model found for this provider.")
                    .foregroundStyle(.secondary)
                Button(controller.id == .mlxlm ? "Choose model folder…" : "Choose model file…") {
                    chooseModel()
                }
                .disabled(modelLocked)
            }

            if (controller.id == .llamacpp || controller.id == .mlxlm)
                && !controller.modelChoices.isEmpty {
                Button("Choose another…") { chooseModel() }
                    .font(.callout)
                    .disabled(modelLocked)
            }

            // Scan/registry status made visible, with an explicit Rescan
            // action for models the user just added or reinstalled.
            HStack(spacing: 8) {
                Text(scanSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // The AX name has to live in the button's label content:
                // a label modifier on the Button itself did not reach the
                // AppKit AX tree in the hosted view (see the note by
                // labelledButton for the full reasoning).
                if !state.modelsDirectory.isEmpty {
                    Button {
                        // One forced walk of the library for the whole app
                        // (the automatic background refreshes keep using the
                        // cache); every provider that lists library models
                        // refreshes from it.
                        state.rescanLibrary()
                    } label: {
                        Text(state.isScanningLibrary ? "Scanning…" : "Rescan")
                            .accessibilityLabel("Rescan \(controller.id.displayName) models")
                    }
                    .font(.caption)
                    .disabled(state.isScanningLibrary
                              || controller.status == .starting
                              || controller.busy == .stopping)
                }
            }
            if controller.id == .llamacpp || controller.id == .mlxlm {
                libraryActions
            }
            if let err = controller.configError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    /// The way out of a missing or unreadable library, next to the words
    /// that describe it. Shown even when a provider still has a manually
    /// selected model: that file keeps working, but discovery is broken.
    @ViewBuilder
    private var libraryActions: some View {
        if state.modelsDirectory.isEmpty || libraryBlocked() {
            HStack(spacing: 8) {
                Button("Choose Model Folder…") { state.chooseModelsDirectory() }
                if !state.modelsDirectory.isEmpty {
                    Button("Retry") { state.retryLibraryFolder() }
                }
                if ModelLibrary.isReadableDirectory(ModelLibrary.recommendedRoot)
                    && state.modelsDirectory != ModelLibrary.recommendedRoot {
                    Button("Use ~/AI/models") { state.useRecommendedLibrary() }
                }
            }
            .font(.callout)
            if !controller.modelChoices.isEmpty {
                Text("The model you selected is still available; only the "
                     + "folder browse is blocked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Retry has to answer here, not only in Settings: this is where
            // the button was pressed. (The standing "cannot read this folder"
            // state is already stated by the summary line above.)
            if let note = state.retryNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A scan that stopped at its time budget must not read as a complete
    /// library: the count is real, but more may be waiting deeper in.
    private var partialSuffix: String {
        ModelLibrary.lastScanPartial()
            ? " Partial scan — some folders were not reached; try Rescan." : ""
    }

    /// True when an empty library is the OS refusing folders, not an empty
    /// folder: a protected root (the home folder for a freshly launched app)
    /// lists at the top level and then denies everything below it.
    private func libraryBlocked() -> Bool {
        ModelLibrary.hasScanned()
            && (!ModelLibrary.rootReadable() || ModelLibrary.lastScanBlocked())
    }

    /// Shown instead of "no models" when the library root exists but the OS
    /// will not let ArcLatch open the folders in it (freshly installed app,
    /// folder access): name the problem and the way out.
    private func unreadableRootText(_ lib: String) -> String {
        "ArcLatch cannot open the model folders in \(lib) — press Retry if the "
        + "disk is not mounted yet, allow folder access in System Settings → "
        + "Privacy & Security → Files and Folders, or choose a different folder."
    }

    /// How many models the scan found, per provider's own source.
    private var scanSummary: String {
        let n = controller.modelChoices.count
        let lib = shortUserPath(state.modelsDirectory)
        if (controller.id == .llamacpp || controller.id == .mlxlm), lib.isEmpty {
            return "No model folder chosen yet."
        }
        switch controller.id {
        case .ollama:
            // The empty case is already stated once in the model section;
            // don't repeat it here.
            return n == 0 ? "" : "\(n) tag(s) in the Ollama store."
        case .llamacpp:
            // The count describes the walk, not what happens to be selected:
            // a hand-picked model file stays listed even when the folder it
            // would have come from cannot be opened.
            if libraryBlocked() { return unreadableRootText(lib) }
            let found = ModelLibrary.ggufFiles().count
            return found == 0 ? "No models found in \(lib)."
                              : "\(found) GGUF model(s) scanned in \(lib).\(partialSuffix)"
        case .mlxlm:
            if libraryBlocked() { return unreadableRootText(lib) }
            let found = ModelLibrary.mlxModelDirs().count
            return found == 0 ? "No models found in \(lib)."
                              : "\(found) MLX model folder(s) scanned in \(lib).\(partialSuffix)"
        case .splash:
            let verified = "\(n) selectable preset\(n == 1 ? "" : "s")"
            if let reg = controller.adapter.registrySummary(profile: controller.profile) {
                return "\(verified) · \(reg)"
            }
            return verified
        }
    }

    @ViewBuilder private var splashModelPicker: some View {
        let profile = controller.profile
        let choices = controller.modelChoices.filter { $0.splashPreset != nil }
        let selection = profile.localModelDir == nil ? profile.splashPreset?.dir : nil
        let selectedID = choices.contains { $0.id == selection } ? selection : nil
        let fallback = profile.localModelDir.map { ($0 as NSString).lastPathComponent }
            ?? "Choose an installed preset"
        if choices.isEmpty {
            Text(profile.localModelDir == nil ? "No launchable Splash presets found." : fallback)
                .foregroundStyle(.secondary)
        } else {
            Picker("Splash model", selection: Binding(
                get: { selectedID },
                set: { if let id = $0 { controller.selectSplashPreset(id) } }
            )) {
                if selectedID == nil { Text(fallback).tag(nil as String?) }
                ForEach(choices) { choice in
                    Text(choice.label).tag(Optional(choice.id))
                }
            }
            .labelsHidden()
            .disabled(modelLocked || controller.busy == .stopping)
            .frame(maxWidth: 480, alignment: .leading)
        }
    }

    private var modelSelectionBinding: Binding<String> {
        Binding(get: { controller.profile.modelID },
                set: { newValue in controller.updateProfile { $0.modelID = newValue } })
    }

    private var pathLine: some View {
        Text(controller.profile.modelID)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Setup issues

    private var setupIssues: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Setup")
                .font(.headline)
            ForEach(Array(controller.checks.enumerated()), id: \.offset) { _, check in
                HStack(spacing: 6) {
                    Image(systemName: check.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(check.ok ? .green : .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(check.label)
                        if let detail = check.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(check.label): \(check.ok ? "ok" : "problem")")
            }
            // Recovery actions themselves live beside Start (see
            // launchProblemRow), where the failed action is; this block keeps
            // the checklist and a re-check of it.
            if !isRunningLike {
                Button("Re-check") {
                    Task { await controller.bootstrap() }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .quaternaryLabelColor)))
    }

    // MARK: Advanced

    private var advancedBinding: Binding<Bool> {
        Binding(
            get: { state.advancedExpanded.contains(controller.id) },
            set: { on in
                if on { state.advancedExpanded.insert(controller.id) }
                else { state.advancedExpanded.remove(controller.id) }
            })
    }

    private var advancedSection: some View {
        DisclosureGroup("Advanced settings", isExpanded: advancedBinding) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Local port")
                    DigitField(title: "Local port", width: 90,
                               value: controller.profile.port,
                               // Editable while stopped or after a conflict/failure,
                               // so an occupied port can be changed. A managed
                               // service's port is read-only: it comes from the
                               // service's own configuration.
                               enabled: !controller.adapter.serviceManagedLaunch
                                        && (controller.status == .stopped
                                            || controller.status.isFailureLike)) { parsed, raw in
                        // Empty commits nothing: a port can't be cleared.
                        guard !raw.isEmpty else { return }
                        if let parsed {
                            controller.updateProfile { $0.port = parsed }
                        } else {
                            controller.portError = "That number is too large to store as a port."
                        }
                    }
                    .id(controller.id)
                }
                if controller.adapter.serviceManagedLaunch {
                    Text("Homebrew-managed port — set in the service's own "
                         + "configuration (OLLAMA_HOST; default 11434).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let err = controller.portError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Text("Executable")
                        .frame(width: 80, alignment: .leading)
                    Text(controller.profile.executablePath)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Locate executable…") { locateExecutable() }
                        .disabled(isRunningLike)
                }
                if controller.id == .splash {
                    HStack {
                        Text("Model files")
                            .frame(width: 80, alignment: .leading)
                        Text(controller.profile.localModelDir ?? "installed preset (offline)")
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseSplashFiles() }
                            .disabled(isRunningLike)
                        if controller.profile.localModelDir != nil {
                            Button("Use preset") {
                                controller.updateProfile {
                                    $0.localModelDir = nil
                                }
                            }
                        }
                    }
                    HStack {
                        Text("Draft")
                            .frame(width: 80, alignment: .leading)
                        Text(controller.profile.draftPath ?? "automatic (DFlash2 draft)")
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { chooseSplashDraft() }
                            .disabled(isRunningLike)
                        if controller.profile.draftPath != nil {
                            Button("Clear") {
                                controller.updateProfile { $0.draftPath = nil }
                            }
                        }
                    }
                }
                if controller.id == .mlxlm {
                    Toggle("Allow custom code for this model", isOn: customCodeBinding)
                        .disabled(isRunningLike)
                    Text(controller.profile.customCodeActive
                         ? "Consent is active for \(controller.profile.modelID). Changing the model clears it."
                         : """
                           Ripple's model folder ships custom Python (ricursive.py). \
                           The server's trust flag is passed only while this switch is on, \
                           and only for the model shown. Changing the model clears consent. \
                           The served model id and port stay as ccmlx expects.
                           """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                runtimeOptions

                HStack {
                    Text("Extra args")
                    TextField("space-separated", text: extraArgsBinding)
                        .disabled(isRunningLike)
                }
                Text("Arguments that would override the model, loopback binding, "
                     + "port, offline mode, or trust policy are refused at Start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Launch-behavior settings apply while the provider is stopped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        }
        .tint(.primary)
    }

    // MARK: Runtime options
    // Same layout on every provider; only the knobs that provider's own
    // server supports (verified against its --help), mapped by the adapter.

    @ViewBuilder private var runtimeOptions: some View {
        let advice = controller.runtimeRecommendation()
        VStack(alignment: .leading, spacing: 8) {
            Text("Runtime options").font(.headline)
            // Suggestions first, so the reason reads before the numbers.
            // Nothing here is applied automatically: an empty field stays the
            // engine's default until **Use recommended** is pressed.
            if controller.id != .ollama {
                Text(advice.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Use recommended") {
                        controller.applyRuntimeRecommendation(advice)
                    }
                    Button("Use engine defaults") {
                        controller.clearRuntimeOptions()
                    }
                }
                .font(.callout)
                .disabled(!knobsEnabled)
            }
            switch controller.id {
            case .llamacpp:
                knob("Context length (tokens)") {
                    VStack(alignment: .leading, spacing: 3) {
                        DigitField(title: "Context length",
                                   placeholder: recommended(advice.contextLength,
                                                            or: "default"),
                                   value: controller.profile.contextLength,
                                   enabled: knobsEnabled) { parsed, raw in
                            commitNumeric(parsed, raw) { controller.setContextLength($0) }
                        }
                        .id(controller.id)
                        // Soft caution, never a hard block: the range
                        // validation stays the gate.
                        if let caution = ramCaution {
                            Text(caution)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                knob("GPU layers (-ngl)") {
                    DigitField(title: "GPU layers", placeholder: "auto (recommended)",
                               value: controller.profile.gpuLayers,
                               enabled: knobsEnabled) { parsed, raw in
                            commitNumeric(parsed, raw) { controller.setGPULayers($0) }
                        }
                        .id(controller.id)
                }
                knob("CPU threads") {
                    DigitField(title: "CPU threads", placeholder: "auto (recommended)",
                               value: controller.profile.threadCount,
                               enabled: knobsEnabled) { parsed, raw in
                            commitNumeric(parsed, raw) { controller.setThreadCount($0) }
                        }
                        .id(controller.id)
                }
            case .splash:
                knob("Context length (tokens)") {
                    VStack(alignment: .leading, spacing: 3) {
                        DigitField(title: "Context length",
                                   placeholder: recommended(advice.contextLength,
                                                            or: "default"),
                                   value: controller.profile.contextLength,
                                   enabled: knobsEnabled) { parsed, raw in
                            commitNumeric(parsed, raw) { controller.setContextLength($0) }
                        }
                        .id(controller.id)
                        if let caution = ramCaution {
                            Text(caution)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                knob("Metal memory budget (GB)") {
                    DigitField(title: "Metal memory budget",
                               placeholder: recommended(advice.maxMemoryGB, or: "auto"),
                               value: controller.profile.maxMemoryGB,
                               enabled: knobsEnabled) { parsed, raw in
                            commitNumeric(parsed, raw) { controller.setMaxMemoryGB($0) }
                        }
                        .id(controller.id)
                }
            case .mlxlm:
                knob("Max tokens per reply") {
                    DigitField(title: "Max tokens per reply",
                               placeholder: recommended(advice.maxTokens, or: "default"),
                               value: controller.profile.maxTokens,
                               enabled: knobsEnabled) { parsed, raw in
                            commitNumeric(parsed, raw) { controller.setMaxTokens($0) }
                        }
                        .id(controller.id)
                }
                knob("Default temperature") {
                    TextField(advice.temperature.map { "\($0) (recommended)" }
                              ?? "engine default",
                              value: doubleBinding(get: { controller.profile.temperature },
                                                   set: { controller.setTemperature($0) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 110)
                }
            case .ollama:
                Text("Ollama has no per-start flags: its runtime options "
                     + "(OLLAMA_CONTEXT_LENGTH, OLLAMA_NUM_THREAD, …) belong to "
                     + "the Homebrew service's own environment. ArcLatch never "
                     + "rewrites the service configuration you installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let err = controller.configError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("Empty uses the engine default. Changes apply at the next Start.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// Field hint text that names the suggested number without filling it in:
    /// the recommendation stays visible, and an empty field is still exactly
    /// the engine's own default. Showing it this way means nothing is written
    /// into a profile just because the app rendered a panel.
    private func recommended(_ value: Int?, or fallback: String) -> String {
        value.map { "\($0) (recommended)" } ?? fallback
    }

    /// Launch-bound knobs stay locked while a server is starting or running;
    /// DigitField takes this explicitly because SwiftUI's .disabled does not
    /// reach NSViewRepresentable-backed controls.
    private var knobsEnabled: Bool {
        !(controller.status == .starting || isRunningLike)
    }

    private func knob(_ label: String, @ViewBuilder _ field: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 180, alignment: .leading)
            field()
            Spacer()
        }
        .disabled(!knobsEnabled)
    }

    /// Shared commit path for digit-only knobs: an empty field commits the
    /// engine default through the validated setter; a digit string too
    /// large for Int reports itself (configError) instead of silently
    /// storing nothing. Out-of-range values keep the existing setter error.
    private func commitNumeric(_ parsed: Int?, _ rawDigits: String,
                               set: (Int?) -> Void) {
        if rawDigits.isEmpty { set(nil); return }
        if let parsed {
            set(parsed)
        } else {
            controller.configError = "That number is too large to store."
        }
    }

    /// RAM-aware sanity caution for the committed context length (orange
    /// line, never a block). Heuristic lives in RAMSanity.
    private var ramCaution: String? {
        guard let ctx = controller.profile.contextLength else { return nil }
        return RAMSanity.warning(contextLength: ctx,
                                 physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    private func doubleBinding(get: @escaping () -> Double?,
                               set: @escaping (Double?) -> Void) -> Binding<Double?> {
        Binding(get: get, set: set)
    }
    private var customCodeBinding: Binding<Bool> {
        Binding(get: { controller.profile.customCodeActive },
                set: { newValue in
                    controller.updateProfile {
                        $0.allowCustomCode = newValue
                        $0.customCodeApprovedModel = newValue ? $0.modelID : nil
                    }
                })
    }
    private var extraArgsBinding: Binding<String> {
        Binding(get: { controller.profile.extraArgs.joined(separator: " ") },
                set: { newValue in
                    controller.updateProfile {
                        $0.extraArgs = newValue.split(separator: " ").map(String.init)
                    }
                })
    }

    // MARK: Actions
    //
    // Accessibility note: every button here carries its AX name inside the
    // label content (`Text(...).accessibilityLabel(...)`) rather than as a
    // modifier on the Button itself. A live System Events probe of the last
    // round showed every hosted button's name as missing value with the
    // outside-on-the-Button form, so the label now rides the same content
    // path SwiftUI uses for the button's visible title — the one variant
    // that reliably reaches the AppKit AX bridge for hosted controls.
    // The visible text stays in the label either way.

    private var actionsRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if controller.status == .starting {
                    Button(role: .cancel, action: { controller.cancelStart() }) {
                        Text("Stop starting")
                            .accessibilityLabel("Cancel starting \(controller.id.displayName)")
                    }
                    ProgressView().controlSize(.small)
                } else if controller.busy == .stopping {
                    // A cancelled start whose service operation is still
                    // settling, or a stop awaiting confirmed exit: controls
                    // stay busy — Start remains disabled until the settle
                    // completes.
                    Button(action: {}) {
                        Text(controller.status == .stopped ? "Cancelling…" : "Stopping…")
                            .accessibilityLabel(controller.status == .stopped
                                                ? "Cancelling \(controller.id.displayName) start"
                                                : "Stopping \(controller.id.displayName)")
                    }
                    .disabled(true)
                    ProgressView().controlSize(.small)
                } else if controller.canStop {
                    Button(action: { controller.stop() }) {
                        Text("Stop")
                            .accessibilityLabel("Stop \(controller.id.displayName)")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(action: { controller.start() }) {
                        Text("Start")
                            .accessibilityLabel("Start \(controller.id.displayName)")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canStart)
                }

                Button(action: { controller.runTest() }) {
                    Text("Test model")
                        .accessibilityLabel("Test \(controller.id.displayName) model")
                }
                .disabled(!controller.canTest)
                if controller.busy == .testing {
                    ProgressView().controlSize(.small)
                }

                // Before the endpoint is ready the copy control stays where it
                // always was, disabled. Once it is ready, the compact endpoint
                // row below replaces it: a wide combo button is wasted on a
                // single loopback URL the user can select by hand anyway.
                if !controller.canCopy {
                    Menu {
                        ForEach(controller.apiURLEntries, id: \.url) { entry in
                            Button { copy(entry) } label: {
                                Text("Copy \(entry.label)")
                            }
                        }
                        if let alt = alternateURL {
                            Button { copyURL(alt, label: "OpenAI-compatible") } label: {
                                Text("Copy OpenAI-compatible URL")
                            }
                        }
                    } label: {
                        Text("Copy API URL")
                            .accessibilityLabel("Copy \(controller.id.displayName) API URL")
                    } primaryAction: {
                        if let first = controller.apiURLEntries.first { copy(first) }
                    }
                    .disabled(true)
                }
            }

            // One-line start-time fit estimate next to the Start button:
            // model weights + a rough KV allowance vs currently free RAM.
            // Orange and tagged "may not fit" when it looks tight. Providers
            // that serve from internal stores (Ollama, Splash) measure no
            // weights, so their estimate is nil and nothing is shown.
            //
            // Before launch only. Once a server is up the figure measures
            // today's free RAM rather than what that server needed, so it is
            // dropped: a run that had already answered a test was being
            // shown a "may not fit" warning nobody could act on. Server state
            // and the last test result cover a running provider instead.
            if showFitEstimate, let estimate = startMemoryEstimate {
                Text(estimate.caption)
                    .font(.caption)
                    .foregroundStyle(estimate.fits ? Color.secondary : Color.orange)
            }

            if controller.canCopy { endpointRow }

            // A launch that failed, was refused, or hit a port in use gets its
            // reason and its way out here — beside the control that produced
            // it — rather than only in the header.
            if controller.status.isFailureLike { launchProblemRow }
        }
    }

    /// Fit guidance is pre-launch guidance.
    private var showFitEstimate: Bool {
        !controller.isEndpointReady
            && controller.status != .starting
            && controller.busy != .starting
    }

    /// The endpoint as text plus a small Copy button: same URL, same clipboard
    //  write, and same confirmation as the old combo button, without the width.
    private var endpointRow: some View {
        HStack(spacing: 8) {
            if let first = controller.apiURLEntries.first {
                Text(first.url)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button {
                    copy(first)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .accessibilityLabel("Copy \(controller.id.displayName) API URL")
                }
                .controlSize(.small)
            }
            let rest = Array(controller.apiURLEntries.dropFirst())
            if !rest.isEmpty || alternateURL != nil {
                Menu {
                    ForEach(rest, id: \.url) { entry in
                        Button { copy(entry) } label: { Text("Copy \(entry.label)") }
                    }
                    if let alt = alternateURL {
                        Button { copyURL(alt, label: "OpenAI-compatible") } label: {
                            Text("Copy OpenAI-compatible URL")
                        }
                    }
                } label: {
                    Text("More")
                        .accessibilityLabel("More \(controller.id.displayName) endpoints")
                }
                .controlSize(.small)
                .fixedSize()
            }
            Spacer(minLength: 4)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var launchProblemRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(controller.detailStatusText, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            if case .portConflict = controller.status,
               !controller.adapter.serviceManagedLaunch {
                Text("Choose a different port under Advanced settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !isRunningLike {
                HStack(spacing: 8) {
                    switch controller.id {
                    case .splash:
                        // Splash presets are identity-bound; recovery is via
                        // the local model files picker.
                        Button("Choose model files…") { chooseSplashFiles() }
                    case .mlxlm:
                        Button("Choose model folder…") { chooseModel() }
                    case .llamacpp:
                        Button("Choose model…") { chooseModel() }
                    case .ollama:
                        EmptyView()
                    }
                    Button("Locate executable…") { locateExecutable() }
                        .disabled(isRunningLike)
                }
                .font(.callout)
                // The raw output stays one click away, in the Recent logs
                // disclosure immediately below.
                Text("Raw output is under Recent logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .quaternaryLabelColor)))
    }

    /// The extra endpoint some providers offer once tested (Ollama's
    /// OpenAI-compatible surface).
    private var alternateURL: String? {
        guard controller.id == .ollama, ollamaTestPassed else { return nil }
        return "http://127.0.0.1:\(controller.profile.port)/v1"
    }

    private func copy(_ entry: APIURLEntry) {
        copyURL(entry.url, label: entry.label)
    }

    private func copyURL(_ url: String, label: String) {
        Clipboard.copy(url)
        controller.copyNote = "Copied \(url) — \(label)"
    }

    /// Weight sizing touches the profile's own model path only (one stat,
    /// or one folder listing for MLX), and the free-RAM side reuses the
    /// strip's published reading rather than calling mach per re-render.
    private var startMemoryEstimate: StartMemoryEstimate? {
        guard let free = state.memory.freeBytes else { return nil }
        return StartMemoryCheck.estimate(
            provider: controller.id,
            profile: controller.profile,
            weights: FileSystemModelWeights(),
            free: PublishedFreeMemory(bytes: free))
    }

    private var ollamaTestPassed: Bool {
        if case .passed = controller.lastTest?.outcome { return true }
        return false
    }

    // MARK: Result line

    @ViewBuilder private var resultSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note = controller.copyNote {
                Label(note, systemImage: "doc.on.doc")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let last = controller.lastTest {
                switch last.outcome {
                case .passed(let model):
                    // Short name in the banner: "Test passed · Qwen3-8B". The
                    // full path or model id sits under it, selectable.
                    let short = ModelDisplayName.short(provider: controller.id,
                                                       profile: controller.profile,
                                                       reported: model)
                    Label("Test passed · \(short)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    let full = model ?? controller.profile.modelID
                    if full != short {
                        Text(full)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                case .failed(let message):
                    Label("Test failed: \(message)", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
                Text("Last tested \(last.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            logsDisclosure
        }
    }

    /// The raw engine output. The reason a launch failed is shown next to the
    /// actions (launchProblemRow); this stays the place for the untranslated
    /// log lines, so nothing is stated twice.
    @ViewBuilder private var logsDisclosure: some View {
        if controller.status.isFailureLike {
            DisclosureGroup("Recent logs") {
                ScrollView {
                    Text(controller.logs.isEmpty
                         ? "No output captured."
                         : controller.logs.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .quaternaryLabelColor)))
        }
    }

    // MARK: Pickers

    private func chooseModel() {
        let isDir = controller.id == .mlxlm
        let path = PathPicker.run(canFiles: !isDir, canDirectories: isDir,
                              startDir: ModelLibrary.currentRoot(), prompt: "Choose")
        guard let path else { return }
        // Refuse picks that cannot be served: a folder is only an MLX
        // model if it carries config.json + safetensors; llama.cpp needs a
        // .gguf file. A rejected pick never enters the dropdown.
        if isDir, !ModelLibrary.isMLXModelFolder(path) {
            controller.configError = "That folder is not an MLX model "
                + "(needs config.json and .safetensors weights)."
            return
        }
        if !isDir, !path.hasSuffix(".gguf") {
            controller.configError = "Choose a .gguf model file."
            return
        }
        controller.configError = nil
        controller.updateProfile { $0.modelID = path }
        controller.reloadModels()
    }

    private func chooseSplashFiles() {
        let path = PathPicker.run(canFiles: true, canDirectories: true,
                              startDir: state.modelsDirectory.isEmpty ? nil : state.modelsDirectory,
                              prompt: "Choose model")
        if let path {
            controller.updateProfile { $0.localModelDir = path }
        }
    }

    private func chooseSplashDraft() {
        let path = PathPicker.run(canFiles: false, canDirectories: true,
                              startDir: NSHomeDirectory() + "/.cache/huggingface",
                              prompt: "Choose draft")
        if let path {
            controller.updateProfile { $0.draftPath = path }
        }
    }

    private func locateExecutable() {
        let path = PathPicker.run(canFiles: true, canDirectories: false,
                              startDir: "/opt/homebrew/bin", prompt: "Locate")
        if let path {
            controller.updateProfile { $0.executablePath = path }
        }
    }
}

/// Hands the estimate the RAM strip's already-published free reading, so
/// body re-renders never re-enter mach.
private struct PublishedFreeMemory: FreeMemorySampling {
    let bytes: UInt64
    func freeBytes() -> UInt64? { bytes }
}
