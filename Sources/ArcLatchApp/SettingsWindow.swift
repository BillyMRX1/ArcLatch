import AppKit
import SwiftUI
import Combine
import ArcLatchCore

// The Settings screen. Same AppKit-shell + NSHostingView bridge as the main
// window (no SwiftUI macro plugin on this toolchain): the controller owns
// the window and re-renders it on state changes.

@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var cancellable: AnyCancellable?
    private var revision = 0

    @objc func showSettings(_ sender: Any?) { show() }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 260),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            w.title = "Settings"
            w.identifier = NSUserInterfaceItemIdentifier("arclatch-settings")
            // Programmatic NSWindows default to isReleasedWhenClosed = true:
            // closing the window would free the object while `window` still
            // points at it, and the next open or Combine re-render crashed
            // with EXC_BAD_ACCESS in objc_msgSend. We own the lifetime.
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(state: .shared,
                                                                 revision: 0))
            window = w
            cancellable = AppState.shared.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self, let host = self.window?
                        .contentView as? NSHostingView<SettingsView> else { return }
                    self.revision += 1
                    host.rootView = SettingsView(state: .shared, revision: self.revision)
                }
        }
        // Re-render on every open so reopened windows show current state
        // even if no objectWillChange fired since the last show.
        if let host = window?.contentView as? NSHostingView<SettingsView> {
            revision += 1
            host.rootView = SettingsView(state: .shared, revision: revision)
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    let state: AppState
    let revision: Int   // bridge re-render counter; referenced to keep intent

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Model library").font(.headline)
            Text(revision >= 0 ? folderLabel : folderLabel)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .quaternaryLabelColor)))

            HStack(spacing: 10) {
                Button("Choose folder…") { state.chooseModelsDirectory() }
                if canSwitchToRecommended {
                    Button("Switch to ~/AI/models") { state.useRecommendedLibrary() }
                }
                if isUnavailable {
                    Button("Retry") { state.retryLibraryFolder() }
                }
                if !ModelLibrary.isBareHomeDefault(state.modelsDirectory) {
                    Button("Use ~ (whole home folder)") {
                        state.setModelsDirectory(ModelLibrary.legacyHomeRoot)
                    }
                }
            }

            if isUnavailable {
                Text("""
                This saved folder cannot be read right now. It stays selected \
                so nothing else takes its place: press Retry once the disk is \
                mounted, or choose another folder.
                """)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if canSwitchToRecommended {
                Text("""
                This is the whole home folder — earlier versions saved it as \
                the default even when nobody chose it. A dedicated model folder \
                (~/AI/models) scans faster and lists only the models you keep; \
                Switch to ~/AI/models moves the library there in one click.
                """)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if state.modelsDirectory.isEmpty {
                Text("""
                No folder is chosen, so nothing is scanned. ArcLatch does not \
                walk the whole home folder on its own: choose the folder that \
                holds your models (~/AI/models if you keep one there).
                """)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if isAutomatic {
                Text("""
                Chosen automatically because nothing was saved yet and \
                ~/AI/models exists. Pick another folder here to override it.
                """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("""
            ArcLatch scans this folder recursively for GGUF models (llama.cpp) \
            and MLX model folders (MLX-LM); models in its subfolders are found \
            too. Background refreshes reuse the last scan; Rescan in a \
            provider's detail pane walks this folder again — one walk for the \
            whole app — so a model you just added, moved, or deleted appears in \
            every provider that can serve it. Hidden folders, application \
            bundles (Photos and Music libraries, apps), and system and tool \
            trees (Library, caches, venvs, node_modules, provider stores, \
            backups) are never opened; the walk stops at depth 5 and after a \
            time budget checked between folder reads, and a folder that is \
            itself a model is listed as one entry. Ollama lists its own store, \
            and Splash uses its installed preset.
            """)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let note = state.retryNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let note = state.libraryNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let note = state.settingsNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 500, minHeight: 230, alignment: .topLeading)
    }

    private var folderLabel: String {
        state.modelsDirectory.isEmpty ? "No folder chosen" : state.modelsDirectory
    }

    private var isUnavailable: Bool {
        if case .unavailable = state.libraryOutcome { return true }
        return false
    }

    private var isAutomatic: Bool {
        if case .automatic = state.libraryOutcome { return true }
        return false
    }

    /// The one-click move only makes sense while the library is still the
    /// old implicit home folder *and* the dedicated folder is readable.
    private var canSwitchToRecommended: Bool {
        guard state.libraryOutcome == .legacyHome(ModelLibrary.legacyHomeRoot) else { return false }
        return ModelLibrary.isReadableDirectory(ModelLibrary.recommendedRoot)
    }
}
