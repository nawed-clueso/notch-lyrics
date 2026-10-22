import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = PlaybackState()
    /// One pill window per connected display. Keyed by NSScreen
    /// (ObjectIdentifier so removed screens get cleaned up).
    private var windows: [ObjectIdentifier: NotchWindow] = [:]
    private var globalRightClickMonitor: Any?
    private var globalOutsideClickMonitor: Any?
    private var screenChangeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppFont.registerAll()

        // The engine no longer subscribes in its initialiser: `AudioEffects` is
        // main-actor state and the engine itself is queue-confined, so the
        // subscriptions are established here, on main, exactly once.
        AudioEngine.shared.observeEffects()

        syncWindowsToScreens()

        // Spawn / despawn windows when displays are plugged in or out.
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncWindowsToScreens() }
        }

        // Right-click anywhere over the pill area → quit menu.
        globalRightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self, let eventWindow = event.window as? NotchWindow,
                  self.windows.values.contains(where: { $0 === eventWindow }) else { return event }
            self.showQuitMenu(over: eventWindow)
            return nil
        }

        // Click anywhere outside our window → collapse the pill if open. Uses GLOBAL
        // monitor because clicks land in other apps' windows, never reaching ours.
        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.state.isHovering { self.state.isHovering = false }
            }
        }

        state.start()

        // A regular app gets its window on launch. First run opens on Setup,
        // since permissions and the loopback bridge can't be inferred.
        MainWindowController.shared.show()
    }

    /// Diffs the current screen list against existing windows: creates one
    /// for each new screen, tears down windows whose screen is gone.
    private func syncWindowsToScreens() {
        let currentScreens = NSScreen.screens
        let currentIDs = Set(currentScreens.map(ObjectIdentifier.init))

        // Remove windows for gone screens.
        for (id, window) in windows where !currentIDs.contains(id) {
            window.orderOut(nil)
            windows.removeValue(forKey: id)
        }
        // Add windows for new screens; re-place the ones we already have, since a
        // resolution or arrangement change moves where "centred" / the notch is.
        for screen in currentScreens {
            let id = ObjectIdentifier(screen)
            if let existing = windows[id] {
                existing.reposition(on: screen)
            } else {
                let w = NotchWindow(state: state, screen: screen)
                w.orderFrontRegardless()
                windows[id] = w
            }
        }
    }

    /// Right-clicking the pill opens the app rather than one pane of it: the
    /// window is where everything lives now, and with the window closed the pill
    /// is the only thing on screen, so it also has to offer Quit.
    private func showQuitMenu(over window: NotchWindow) {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Notch Lyrics", action: #selector(showMainWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Notch Lyrics", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: window.contentView ?? NSView())
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Menu bar actions

    @objc func showMainWindow() {
        MainWindowController.shared.show()
    }

    @objc func showSetupPane() {
        MainWindowController.shared.show(pane: .setup)
    }

    @objc func showAudioPane() {
        MainWindowController.shared.show(pane: .audio)
    }

    // MARK: - Standard app window behaviour

    /// Closing the window leaves the notch pill running, so don't terminate.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon (or re-launching) brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainWindowController.shared.show() }
        return true
    }
}
