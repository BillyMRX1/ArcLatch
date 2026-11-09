import SwiftUI
import ArcLatchCore

// SwiftUI content with no macro-based property wrappers (see AppState.swift).
// The AppKit bridge rebuilds this root view on every observable change.

struct RootView: View {
    let state: AppState
    let revision: Int

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                // Narrow default, still draggable: HSplitView keeps the divider
                // live between the minimum and maximum below.
                SidebarView(state: state, revision: revision)
                    .frame(minWidth: 200, idealWidth: 240, maxWidth: 400)
                DetailView(state: state, revision: revision)
                    .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            RAMStripView(state: state, revision: revision)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 840, minHeight: 520)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    let state: AppState
    // Without the SwiftUI observation macros, the bridge bumps `revision` so
    // SwiftUI sees these structs as changed and re-runs their bodies.
    let revision: Int

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(
                get: { state.selected },
                set: { if let id = $0 { state.selected = id } }
            )) {
                Section("Providers") {
                    ForEach(state.controllers) { controller in
                        SidebarRow(controller: controller, revision: revision)
                            .tag(controller.id)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Model library")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(state.modelsDirectory.isEmpty
                         ? "No folder chosen"
                         : homeFriendlyPath(state.modelsDirectory))
                        .font(.system(.caption, design: .monospaced))
                        .help(state.modelsDirectory.isEmpty
                              ? "No model folder chosen yet (Settings…, ⌘,)."
                              : state.modelsDirectory)
                    // A whole-home library only happens if the user chose it
                    // or an older build saved it; either way the dedicated
                    // folder is the better answer, and Settings switches.
                    if ModelLibrary.isBareHomeDefault(state.modelsDirectory) {
                        Text("Home folder — Settings… can switch to ~/AI/models.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if state.modelsDirectory.isEmpty {
                        Text("Choose a model folder in Settings… (⌘,) to list your models.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    state.openSettings()
                } label: {
                    // AX name in the label content, like DetailView's
                    // action buttons: the outside-the-Button form did not
                    // reach the hosted AppKit AX tree.
                    Label("Settings", systemImage: "gearshape")
                        .accessibilityLabel("Open Settings")
                }
                .help("Open Settings (⌘,): choose the model library folder.")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }
}

struct SidebarRow: View {
    let controller: ProviderController
    let revision: Int

    var body: some View {
        HStack {
            Text(controller.id.displayName)
            Spacer()
            if controller.busy == .testing {
                ProgressView().controlSize(.small)
            }
            Text(controller.status.sidebarText)
                .font(.callout)
                .foregroundStyle(StatusStyle.color(for: controller.status))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(controller.id.displayName), \(controller.status.sidebarText)")
    }
}

/// Friendly home-relative label for the model library path: "~/AI/models"
/// style for subfolders; when the root is the home folder itself, a bare
/// "~" is cryptic, so it gets labeled as such. The full path is always in
/// the help tooltip.
private func homeFriendlyPath(_ path: String) -> String {
    path == NSHomeDirectory() ? "~ (home folder)" : shortUserPath(path)
}

// MARK: - Status styling (text plus color, never color alone)

enum StatusStyle {
    static func color(for status: ServerStatus) -> Color {
        switch status {
        case .stopped: return .secondary
        case .starting: return .orange
        case .ready: return .green
        case .runningExternally: return .blue
        case .portConflict, .failed: return .red
        case .needsSetup: return Color(nsColor: .systemOrange)
        }
    }
}

// MARK: - RAM strip

struct RAMStripView: View {
    let state: AppState
    let revision: Int

    var body: some View {
        HStack(spacing: 14) {
            Text("System RAM")
                .font(.callout.weight(.semibold))
            if let sample = state.memory.sample {
                Text("\(RAMFormat.gib(sample.usedBytes)) / \(RAMFormat.gib(sample.totalBytes)) GB · estimated RAM used")
                    .monospacedDigit()
                RAMMeterView(fraction: sample.fraction)
                    .frame(width: 120, height: 14)
                    .accessibilityHidden(true)
            } else {
                Text("RAM reading unavailable")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Memory pressure")
                .font(.callout.weight(.semibold))
            Text(state.memory.pressure.label)
                .font(.callout)
                .foregroundStyle(pressureColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(pressureColor.opacity(0.14)))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ramAccessibilityLabel)
        .help("Estimated RAM used = app (anonymous) memory + wired + compressed. "
              + "Reclaimable file cache is excluded, so the figure approximates "
              + "Activity Monitor's Memory Used without claiming to match it exactly. "
              + "Memory pressure is a separate reading from macOS's kernel pressure "
              + "level and shows Unavailable until a real reading exists.")
    }

    private var pressureColor: Color {
        switch state.memory.pressure {
        case .unknown: return .secondary
        case .normal: return .green
        case .elevated: return .orange
        case .high: return .red
        }
    }

    private var ramAccessibilityLabel: String {
        if let sample = state.memory.sample {
            return "Estimated RAM used: \(RAMFormat.gib(sample.usedBytes)) of "
                + "\(RAMFormat.gib(sample.totalBytes)) gigabytes. "
                + "Memory pressure \(state.memory.pressure.label)."
        }
        return "RAM reading unavailable. Memory pressure \(state.memory.pressure.label)."
    }
}

struct RAMMeterView: View {
    var fraction: Double

    var body: some View {
        GeometryReader { geo in
            let segments = 10
            let spacing: CGFloat = 3
            let width = (geo.size.width - spacing * CGFloat(segments - 1)) / CGFloat(segments)
            let filled = min(segments, max(0, Int((fraction * Double(segments)).rounded())))
            HStack(spacing: spacing) {
                ForEach(0..<segments, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(index < filled ? meterColor : Color(nsColor: .quaternaryLabelColor))
                        .frame(width: width)
                }
            }
        }
    }

    private var meterColor: Color {
        if fraction >= 0.9 { return .red }
        if fraction >= 0.75 { return .orange }
        return Color(nsColor: .controlAccentColor)
    }
}
