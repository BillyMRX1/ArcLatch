import Foundation

/// User-entered or previously saved "extra arguments" must never be able to
/// override the launch invariants ArcLatch enforces: the selected model, the
/// loopback binding, the chosen port, Splash's offline mode, and MLX-LM's
/// trust policy. Reserved flags are rejected before a process ever launches.
public enum ArgumentGuard {
    /// Flags whose value ArcLatch sets itself; a user repeat would override it.
    public static func reservedFlags(for id: ProviderID) -> Set<String> {
        switch id {
        case .ollama:
            // Service-managed; extra args never reach a launch.
            return []
        case .splash:
            // `--model` is the API id, `--model-dir`/`--mmproj`/`--draft-model`
            // are the local files ArcLatch resolves from the verified bundle,
            // and the served-name flags would republish that id: all of them
            // are ArcLatch's to set, never a user repeat. `--revision` would
            // push launch back onto the Hub, which `--model-dir` forbids.
            return ["serve", "--model", "--model-dir", "--draft-model", "--mmproj",
                    "--revision", "--language-only",
                    "--served-model-name", "--announce-served-name",
                    "--port", "--host", "--offline", "--no-offline",
                    "--max-context", "--max-memory"]
        case .mlxlm:
            return ["--model", "--host", "--port", "--trust-remote-code",
                    "--max-tokens", "--temp"]
        case .llamacpp:
            return ["-m", "--model", "--model-dot-llama", "--host", "--port",
                    "-c", "--ctx-size",
                    "-ngl", "--gpu-layers", "--n-gpu-layers",
                    "-t", "--threads"]
        }
    }

    /// Tokens that attempt to override a reserved flag, in bare, `--flag v`,
    /// or `--flag=v` form.
    public static func violations(_ extraArgs: [String], for id: ProviderID) -> [String] {
        let reserved = reservedFlags(for: id)
        guard !reserved.isEmpty else { return [] }
        return extraArgs.filter { token in
            if reserved.contains(token) { return true }
            if let eq = token.firstIndex(of: "=") {
                return reserved.contains(String(token[..<eq]))
            }
            return false
        }
    }

    public static func rejectionMessage(_ bad: [String]) -> String {
        "Extra arguments cannot override the model, loopback binding, port, "
        + "offline mode, trust policy, or the structured runtime options. "
        + "Use the fields above instead. Remove: " + bad.joined(separator: ", ")
    }
}

/// Ports must be valid TCP ports before they are saved, probed, or launched.
public func isValidPort(_ port: Int) -> Bool { (1...65535).contains(port) }

public let portRangeMessage = "Port must be between 1 and 65535."
