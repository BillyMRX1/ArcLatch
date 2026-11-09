import AppKit
import SwiftUI
import Combine
import ArcLatchCore

// AppKit shell hosting the SwiftUI content (see AppState.swift for why).
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var hosting: NSHostingView<RootView>!
    private var cancellable: AnyCancellable?
    private var rebuildScheduled = false
    private var revision = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState.shared

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "ArcLatch"
        window.identifier = NSUserInterfaceItemIdentifier("arclatch-main")
        window.center()
        window.setFrameAutosaveName("ArcLatchMainWindow")
        hosting = NSHostingView(rootView: RootView(state: state, revision: 0))
        window.contentView = hosting
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        // HSplitView ignores the sidebar's idealWidth and parks the divider
        // at the sidebar's maximum, and a split view does not remember where
        // its divider was: both the default and the user's own width have to
        // be applied and stored here.
        applySidebarWidth(remaining: 12)

        // Rebuild the SwiftUI tree whenever any observed object changes.
        cancellable = state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRebuild() }

        state.bootstrapIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--settings") {
            SettingsWindowController.shared.show()
        }
    }

    // The narrow sidebar is a design default the split view will not keep for
    // us, so it is applied on every launch — and it has to win a race: the
    // split view may not exist on the first pass, and SwiftUI re-applies its
    // own divider position (the sidebar's maximum) during the window's first
    // layout. Re-apply on a short schedule until it sticks.
    private static let sidebarDefaultWidth = 240.0
    private static let sidebarWidthKey = "ArcLatchSidebarWidth"
    private var sidebarDone = false
    private var sidebarApplied = 0.0
    private var sidebarDragToken: (any NSObjectProtocol)?

    /// Where the user left the sidebar, or the design default.
    private static var savedSidebarWidth: Double {
        let saved = UserDefaults.standard.double(forKey: sidebarWidthKey)
        return saved > 100 ? saved : sidebarDefaultWidth
    }

    private func applySidebarWidth(remaining: Int) {
        guard !sidebarDone, remaining > 0 else { return }
        // Spelled out as DispatchTime: `.now() + 0.1` alone is ambiguous with
        // the DispatchWallTime overload (which takes a work item).
        let retryAt = DispatchTime.now() + 0.1
        DispatchQueue.main.asyncAfter(deadline: retryAt) { [weak self] in
            guard let self, !self.sidebarDone else { return }
            guard let split = Self.firstSplitView(in: self.window.contentView) else {
                self.applySidebarWidth(remaining: remaining - 1)
                return
            }
            // Reading the divider: the first pane's right edge. (This SDK's
            // Swift overlay does not import -dividerPositions.)
            let target = Self.savedSidebarWidth
            let current = Double(split.subviews.first?.frame.maxX ?? -1)
            self.sidebarApplied = target
            if abs(current - target) < 1 {
                self.sidebarDone = true
                self.watchSidebarDrags(split)
            } else {
                split.setPosition(CGFloat(target), ofDividerAt: 0)
                self.applySidebarWidth(remaining: remaining - 1)
            }
        }
    }

    /// Once the width has landed, remember a drag the user makes: the divider
    /// position is the one piece of window layout AppKit will not persist for
    /// a SwiftUI-hosted split view.
    private func watchSidebarDrags(_ split: NSSplitView) {
        guard sidebarDragToken == nil else { return }
        sidebarDragToken = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: split, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let position = Double(split.subviews.first?.frame.maxX ?? -1)
            guard position > 100, abs(position - self.sidebarApplied) > 1 else { return }
            self.sidebarApplied = position
            UserDefaults.standard.set(position, forKey: Self.sidebarWidthKey)
        }
    }

    private static func firstSplitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView { return split }
        for sub in view.subviews {
            if let split = firstSplitView(in: sub) { return split }
        }
        return nil
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            self.revision += 1
            self.hosting.rootView = RootView(state: AppState.shared, revision: self.revision)
        }
    }

    // Pause sampling when hidden; resume immediately on reopen.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        let visible = window.occlusionState.contains(.visible)
        AppState.shared.memory.setWindowVisible(visible)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = AppState.shared
        guard state.anyServerArcLatchOwns else { return .terminateNow }
        guard state.confirmQuitWithRunningServers() else { return .terminateCancel }
        // Wait for confirmed shutdown of every server ArcLatch owns — never a
        // fixed delay. If any fails to exit, keep the app open and show why.
        Task { @MainActor in
            let failures = await state.stopServersForQuit()
            if failures.isEmpty {
                NSApp.reply(toApplicationShouldTerminate: true)
            } else {
                state.quitNote = "ArcLatch could not stop: "
                    + failures.joined(separator: ", ")
                    + ". Those servers are still running, so ArcLatch did not quit."
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}

// Minimal native menu (AppKit needs one; SwiftUI would have provided it).
func buildMainMenu() -> NSMenu {
    let mainMenu = NSMenu()

    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About ArcLatch",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
    appMenu.addItem(.separator())
    let settingsItem = appMenu.addItem(withTitle: "Settings…",
                                       action: #selector(SettingsWindowController
                                            .shared.showSettings(_:)),
                                       keyEquivalent: ",")
    settingsItem.target = SettingsWindowController.shared
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide ArcLatch",
                    action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    let others = appMenu.addItem(withTitle: "Hide Others",
                                 action: #selector(NSApplication.hideOtherApplications(_:)),
                                 keyEquivalent: "h")
    others.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(withTitle: "Show All",
                    action: #selector(NSApplication.unhideAllApplications(_:)),
                    keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit ArcLatch",
                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu

    // Standard Edit menu: without these items, ⌘X/⌘C/⌘V/⌘A never reach the
    // responder chain, so text fields (and the Settings fields) have no
    // working select-all or clipboard shortcuts. Targets stay nil so AppKit
    // routes each action to the current first responder.
    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redoItem.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenuItem.submenu = editMenu

    let windowMenuItem = NSMenuItem()
    mainMenu.addItem(windowMenuItem)
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Minimize",
                       action: #selector(NSWindow.performMiniaturize(_:)),
                       keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom",
                       action: #selector(NSWindow.performZoom(_:)),
                       keyEquivalent: "")
    windowMenuItem.submenu = windowMenu
    NSApp.windowsMenu = windowMenu

    return mainMenu
}
