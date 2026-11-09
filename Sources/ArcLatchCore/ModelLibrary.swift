import Foundation

/// One shared walk of the global model library (the user's model folder,
/// `~` by default). Models are
/// classified by format, not by folder convention: whatever the user drops
/// into the library appears automatically under every provider that can
/// serve that format. Provider-internal stores and app caches are skipped,
/// and the walk is depth-bounded so caches/monorepos can't stall startup.
public enum ModelLibrary {
    public enum Kind: Sendable { case gguf, mlxDir }
    public struct Entry: Equatable, Sendable {
        public var path: String
        public var kind: Kind
        public init(path: String, kind: Kind) { self.path = path; self.kind = kind }
    }

    // MARK: Active library root (user-settable)

    /// A dedicated model folder rather than the whole home folder: what
    /// ArcLatch uses on its own whenever the user has expressed no preference.
    public static var recommendedRoot: String { NSHomeDirectory() + "/AI/models" }

    /// The value older builds wrote out even when the user never chose
    /// anything, so it cannot be told apart from an intentional pick of the
    /// home folder. It is honored (a saved choice is never silently replaced)
    /// and reported as `.legacyHome`, which is what lets Settings offer a
    /// one-click switch instead.
    public static let legacyHomeRoot = NSHomeDirectory()

    /// "The home folder", for the Settings affordance and test cleanup. No
    /// longer an automatic pick: nothing walks the whole home folder unless
    /// the user chose it.
    public static var defaultRoot: String { legacyHomeRoot }

    /// No folder chosen: discovery is off, and the UI asks for a folder
    /// instead of reporting an empty library.
    public static let noRoot = ""

    private static let rootLock = NSLock()
    private static var _root: String = noRoot
    private static var _rootReadable = false
    private static var _scanBlocked = false
    private static var _scanPartial = false
    private static var _scanRan = false
    private static var _rootGeneration = 0

    /// False when the last active-root scan could not even list the root
    /// folder (permissions/TCC) — an empty library then means "blocked",
    /// not "nothing here".
    public static func rootReadable() -> Bool {
        rootLock.lock(); defer { rootLock.unlock() }
        return _rootReadable
    }

    /// True when the last active-root scan had a folder refused: the root
    /// itself would not list, or a folder inside it did (TCC commonly lets a
    /// fresh app list the top level of a protected folder and then denies
    /// every folder below it, which looks exactly like an empty library).
    /// Only meaningful when the scan found nothing — a partial scan is still
    /// a usable library.
    public static func lastScanBlocked() -> Bool {
        rootLock.lock(); defer { rootLock.unlock() }
        return _scanBlocked
    }

    /// False until an active-root scan has actually run: "unreadable" and
    /// "partial" only mean something about a scan that happened.
    public static func hasScanned() -> Bool {
        rootLock.lock(); defer { rootLock.unlock() }
        return _scanRan
    }

    /// True when the last active-root scan hit its time budget and stopped
    /// early: what it found is real, but the library may hold more.
    public static func lastScanPartial() -> Bool {
        rootLock.lock(); defer { rootLock.unlock() }
        return _scanPartial
    }

    public static func currentRoot() -> String {
        rootLock.lock(); defer { rootLock.unlock() }
        return _root
    }

    /// False while no folder is chosen: the UI must ask for one, not say
    /// "no models found".
    public static func hasRoot(_ path: String? = nil) -> Bool {
        let r = path ?? { rootLock.lock(); defer { rootLock.unlock() }; return _root }()
        return !r.isEmpty
    }

    /// A folder ArcLatch can actually read: it exists, is a folder, and can
    /// be listed. A path that is merely present is not enough — an external
    /// volume can be there and still refuse to open.
    public static func isReadableDirectory(_ path: String) -> Bool {
        guard isDirectory(path) else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
    }

    /// The automatic choice, when there is one: `~/AI/models` if it is there
    /// and readable. Never the home folder.
    public static func autoRoot(recommending candidate: String = recommendedRoot) -> String? {
        isReadableDirectory(candidate) ? candidate : nil
    }

    public static func setRoot(_ path: String) {
        rootLock.lock()
        _root = path
        // Any in-flight walk of the previous folder is now stale: its results
        // are dropped rather than published (see `scan`).
        _rootGeneration += 1
        cacheRoot = nil; cacheEntries = nil
        rootLock.unlock()
    }

    private static var cacheRoot: String?
    private static var cacheEntries: [Entry]?

    /// What the persisted setting resolved to, so the UI can act on each
    /// case instead of guessing from a path.
    public enum RootOutcome: Equatable, Sendable {
        case automatic(String)     // nothing saved; `~/AI/models` is in use
        case chosen(String)        // a folder the user picked
        case legacyHome(String)    // the old implicit "~": honored, worth offering the switch
        case unavailable(String)   // saved folder is gone: still shown, with Retry / Choose
        case noFolderChosen        // nothing saved, no readable `~/AI/models`
    }

    /// Decide the library from the persisted setting. A saved choice is
    /// honored even when the folder cannot be read right now — an unmounted
    /// volume should be retried, not silently swapped for a different
    /// library — and the path stays set so the UI can name it.
    @discardableResult
    public static func resolveRoot(saved: String?,
                                   autoCandidate: String? = nil) -> RootOutcome {
        if let saved, saved.isEmpty { return resolveRoot(saved: nil, autoCandidate: autoCandidate) }
        let candidate = autoRoot(recommending: autoCandidate ?? recommendedRoot)
        guard let saved else {
            if let candidate {
                setRoot(candidate)
                return .automatic(candidate)
            }
            setRoot(noRoot)
            return .noFolderChosen
        }
        if saved == legacyHomeRoot {
            setRoot(saved)
            return .legacyHome(saved)
        }
        setRoot(saved)
        return isReadableDirectory(saved) ? .chosen(saved) : .unavailable(saved)
    }

    public static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && isDir.boolValue
    }

    /// Directories whose contents are managed by other tools (content-hashed
    /// stores, caches, build trees, unrelated apps) — never user-dropped
    /// models. Matched at any depth, so a home-folder default scan stays
    /// cheap and noise-free.
    static let skippedDirectories: Set<String> = [
        "ollama", "huggingface-hub", "comfyui", "benchmarks", "hermes",
        "omnivoice", "blobs", "snapshots", "refs", "__pycache__",
        "library", "node_modules", "venv", "venvs", "site-packages",
        "build", "dist", "model-backups",
    ]

    /// Folder *packages*: application-managed stores, never user-dropped
    /// models. Skipping these is not just tidiness — opening some of them
    /// blocks in the kernel. On a real Mac, a home-folder scan stalled
    /// forever at `~/Pictures/Photos Library.photoslibrary`, held by a
    /// background daemon, which wedged that provider and (with startup
    /// serialized) every provider behind it.
    static let skippedSuffixes: [String] = [
        ".photoslibrary", ".musiclibrary", ".library", ".aplib",
        ".app", ".bundle", ".framework", ".plugin", ".kext", ".component",
    ]

    /// Safety cap on directories visited per scan (defends exotic roots
    /// like `/` from turning into a disk-wide crawl).
    static let folderBudget = 30_000

    /// Wall-clock cap on one scan, checked **between** filesystem calls: it
    /// bounds how long a walk is willing to keep going on slow or spinning
    /// storage, and it cannot interrupt a call already blocked in the kernel
    /// — that is what the bundle exclusions above are for. A half-scan the
    /// user is told about beats a provider whose model list never arrives.
    static let scanTimeBudget: TimeInterval = 15

    /// GGUF filenames that are accessories, not stand-alone models
    /// (llama.cpp vision projectors, bundled tokenizer vocab files).
    static func isAccessoryGGUF(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("mmproj") || lower.hasPrefix("ggml-vocab")
    }

    /// Split GGUFs (`Name-00002-of-00004.gguf`) list once: llama.cpp loads
    /// the first shard and opens its siblings itself.
    static func isLaterSplitShard(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard let of = lower.range(of: "-of-"), of.lowerBound != lower.startIndex else {
            return false
        }
        var digitsStart = of.lowerBound
        var count = 0
        while digitsStart != lower.startIndex, count < 5 {
            let prev = lower.index(before: digitsStart)
            guard lower[prev].isNumber else { break }
            digitsStart = prev
            count += 1
        }
        guard count == 5, digitsStart != lower.startIndex,
              lower[lower.index(before: digitsStart)] == "-" else { return false }
        let index = String(lower[digitsStart..<of.lowerBound])
        return index != "00001"
    }

    /// Depth 5 from the root so a home-folder default still reaches
    /// `~/AI/models/lmstudio/<org>/<model>` style layouts. Results for the
    /// active root are cached, which is what background auto-refresh reads;
    /// `force: true` (or `refresh()`) always walks the disk again, so models
    /// the user just added or removed appear on the next Rescan.
    public static func scan(root: String? = nil, maxDepth: Int = 5, force: Bool = false,
                            timeBudget: TimeInterval? = nil) -> [Entry] {
        let r = root ?? currentRoot()
        var token = 0
        if root == nil {
            guard !r.isEmpty else {
                // No folder chosen: there is nothing to discover, and "no
                // models here" would be the wrong thing to tell the user.
                rootLock.lock()
                _rootReadable = false; _scanBlocked = false; _scanPartial = false
                cacheRoot = nil; cacheEntries = nil
                rootLock.unlock()
                return []
            }
            // Distinguish "no models here" from "the OS will not let us
            // read this folder" (TCC can silently deny a fresh unsigned
            // app on a home-folder root; a real permission problem needs
            // an actionable message, not an empty library).
            let listable = (try? FileManager.default.contentsOfDirectory(atPath: r)) != nil
            rootLock.lock()
            _rootReadable = listable
            token = _rootGeneration       // guards against a folder change mid-walk
            rootLock.unlock()
        }
        if root == nil, !force {
            rootLock.lock()
            let cached = cacheRoot == r ? cacheEntries : nil
            rootLock.unlock()
            if let cached { return cached }
        }
        var out: [Entry] = []
        var visited = 0
        var denied = 0
        var timedOut = false
        var seenReal: Set<String> = []
        let deadline = Date().addingTimeInterval(timeBudget ?? scanTimeBudget)
        scanWalk(dir: r, depth: 0, maxDepth: maxDepth, deadline: deadline,
                 into: &out, visited: &visited, denied: &denied,
                 timedOut: &timedOut, seenReal: &seenReal,
                 fm: FileManager.default)
        let sorted = out.sorted { $0.path < $1.path }
        if root == nil {
            rootLock.lock()
            // The user may have switched folders while this walk was running;
            // results from the previous folder are dropped, not published.
            let stale = _rootGeneration != token || _root != r
            if !stale {
                _scanRan = true
                _scanBlocked = !_rootReadable || denied > 0
                _scanPartial = timedOut
                cacheRoot = r; cacheEntries = sorted
            }
            rootLock.unlock()
            if stale {
                if debugWalk {
                    FileHandle.standardError.write(
                        Data("scan \(r): discarded (library changed mid-scan)\n".utf8))
                }
                return []
            }
            if debugWalk {
                FileHandle.standardError.write(Data((
                    "scan \(r): \(sorted.count) entries, \(visited) dirs visited, "
                    + "\(denied) folders refused, partial=\(timedOut), "
                    + "rootListable=\(_rootReadable)\n").utf8))
            }
        }
        return sorted
    }

    /// One guaranteed-fresh walk of the active root, replacing the cache:
    /// what the **Rescan** button does. Until it returns, a model file added,
    /// renamed, or deleted is invisible to every provider.
    @discardableResult
    public static func refresh(root: String? = nil, maxDepth: Int = 5) -> [Entry] {
        scan(root: root, maxDepth: maxDepth, force: true)
    }

    /// True when the library is the whole home folder — only the case
    /// because the user picked it, or because an older build saved it as the
    /// implicit default. Either way it is worth offering the dedicated
    /// folder, since a home walk is broad and slow.
    public static func isBareHomeDefault(_ path: String? = nil) -> Bool {
        (path ?? currentRoot()) == legacyHomeRoot
    }

    public static func ggufFiles(root: String? = nil) -> [String] {
        scan(root: root).filter { $0.kind == .gguf }.map { $0.path }
    }

    public static func mlxModelDirs(root: String? = nil) -> [String] {
        scan(root: root).filter { $0.kind == .mlxDir }.map { $0.path }
    }

    internal static var walkHookForTesting: ((String) -> Void)?

    /// `ARC_LATCH_DEBUG_SCAN=1` traces a scan for bug reports: an empty
    /// library is otherwise indistinguishable from a folder the OS withheld.
    static var debugWalk: Bool {
        ProcessInfo.processInfo.environment["ARC_LATCH_DEBUG_SCAN"] != nil
    }

    private static func scanWalk(dir: String, depth: Int, maxDepth: Int,
                                 deadline: Date,
                                 into out: inout [Entry], visited: inout Int,
                                 denied: inout Int, timedOut: inout Bool,
                                 seenReal: inout Set<String>, fm: FileManager) {
        if Date() > deadline {
            timedOut = true    // slow media: report a partial scan, never hang
            return
        }
        // Follow each real folder once: symlinked aliases (e.g. a library
        // folder also linked into Documents) list once, and symlink cycles
        // can never spin the walk.
        var cwd = dir
        if let resolved = realpath(dir, nil) {
            cwd = String(cString: resolved)
            free(resolved)
        }
        if !seenReal.insert(cwd).inserted { return }
        // Test seam: lets a test change the active folder in the middle of a
        // walk and check that the old walk's results never land.
        if depth == 0 { walkHookForTesting?(dir) }
        // A folder that is itself a model is a leaf: classify, don't descend.
        if depth > 0, isMLXDir(cwd, fm) {
            out.append(Entry(path: dir, kind: .mlxDir))
            return
        }
        guard depth < maxDepth, visited < folderBudget else { return }
        if debugWalk, depth <= 1 {
            // Traced before the call: one open() can block, and the last line
            // then names the subtree that blocked.
            FileHandle.standardError.write(Data("  list[\(depth)] \(dir)\n".utf8))
        }
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else {
            // The walk reached this folder and the OS refused to open it:
            // exactly the state that makes a protected folder look empty.
            if depth > 0 {
                denied += 1
                if debugWalk, denied <= 5 {
                    FileHandle.standardError.write(Data("  refused: \(dir)\n".utf8))
                }
            }
            return
        }
        visited += 1
        for name in names.sorted() {
            let lower = name.lowercased()
            if name.hasPrefix(".") || skippedDirectories.contains(lower)
               || skippedSuffixes.contains(where: { lower.hasSuffix($0) }) { continue }
            let path = dir + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                scanWalk(dir: path, depth: depth + 1, maxDepth: maxDepth,
                         deadline: deadline, into: &out, visited: &visited,
                         denied: &denied, timedOut: &timedOut,
                         seenReal: &seenReal, fm: fm)
            } else if lower.hasSuffix(".gguf"), !isAccessoryGGUF(name),
                      !isLaterSplitShard(name) {
                out.append(Entry(path: path, kind: .gguf))
            }
        }
    }

    /// Public check: does this folder look like an MLX-serveable model?
    public static func isMLXModelFolder(_ dir: String) -> Bool {
        isMLXDir(dir, FileManager.default)
    }

    /// The same shape setupChecks uses: an MLX-serveable folder carries
    /// config.json plus safetensors weights.
    static func isMLXDir(_ dir: String, _ fm: FileManager) -> Bool {
        guard fm.fileExists(atPath: dir + "/config.json"),
              let entries = try? fm.contentsOfDirectory(atPath: dir) else { return false }
        return entries.contains { $0.hasSuffix(".safetensors") }
    }
}
