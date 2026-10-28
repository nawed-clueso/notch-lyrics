import AppKit
import SwiftUI

// MARK: - Panes

enum AppPane: String, CaseIterable, Identifiable {
    case setup, audio, lyrics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setup: "Setup"
        case .audio: "Audio"
        case .lyrics: "Lyrics"
        }
    }

    var icon: String {
        switch self {
        case .setup: "checklist"
        case .audio: "slider.horizontal.3"
        case .lyrics: "quote.bubble"
        }
    }

    var blurb: String {
        switch self {
        case .setup: "Permissions and routing"
        case .audio: "Presets, EQ, effects"
        case .lyrics: "Where lyrics come from"
        }
    }
}

// MARK: - First-run flag

enum OnboardingState {
    /// Bump to re-run setup once for existing installs after adding a step.
    private static let currentVersion = 1
    private static let key = "onboarding.completedVersion"

    static var hasCompleted: Bool {
        UserDefaults.standard.integer(forKey: key) >= currentVersion
    }

    static func markCompleted() {
        UserDefaults.standard.set(currentVersion, forKey: key)
    }
}

// MARK: - Window

/// The app's single main window. An ordinary document-style Mac window:
/// resizable, zoomable, full-screenable, and it remembers where you left it.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()

    private var window: NSWindow?

    func show(pane: AppPane? = nil) {
        if let w = window {
            if let pane { selection.pane = pane }
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // First launch lands on Setup; afterwards the app opens on Audio.
        selection.pane = pane ?? (OnboardingState.hasCompleted ? .audio : .setup)

        let host = NSHostingController(rootView: MainView(selection: selection))
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        w.title = "Notch Lyrics"
        w.contentViewController = host
        w.minSize = NSSize(width: 940, height: 620)
        w.backgroundColor = SP.bg
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = false
        // Explicit rather than relying on the default for resizable windows.
        w.collectionBehavior.insert(.fullScreenPrimary)
        // Single-window app: window tabs would only add a confusing affordance.
        w.tabbingMode = .disallowed
        w.delegate = self
        w.isReleasedWhenClosed = false

        // NSHostingController resizes the window to the SwiftUI view's fitting
        // size, which collapses to `minWidth`/`minHeight` — the window opened at
        // 940x648 instead of the contentRect above. Set the content size after
        // installing the controller, then let a saved frame win if there is one.
        w.setContentSize(NSSize(width: 1180, height: 780))
        w.center()
        let frameKey = "NotchLyricsMainWindow"
        w.setFrameUsingName(frameKey)
        w.setFrameAutosaveName(frameKey)

        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    /// Shared so the menu bar and the window can both drive pane selection.
    let selection = PaneSelection()

    /// Dropping the hosting controller tears the SwiftUI tree down. Without it
    /// the window merely hides (`isReleasedWhenClosed` is false), `onDisappear`
    /// never fires, and the setup probe keeps polling TCC and CoreAudio every
    /// 1.5s for the rest of the session.
    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === window else { return }
        w.delegate = nil
        w.contentViewController = nil
        window = nil
    }
}

/// Pane selection lives outside the view tree so the Window menu can change it.
@MainActor
final class PaneSelection: ObservableObject {
    @Published var pane: AppPane = .audio
}

// MARK: - Root view

struct MainView: View {
    @ObservedObject var selection: PaneSelection

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: selection)
            Divider().overlay(SP.divider)
            detail
        }
        .background(SP.bgColor)
        .foregroundStyle(SP.textPrimary)
        .frame(minWidth: 940, minHeight: 620)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection.pane {
        case .setup:
            OnboardingPane {
                OnboardingState.markCompleted()
                withAnimation(Motion.overlay) { selection.pane = .audio }
            }
        case .audio:
            AudioEffectsPane()
        case .lyrics:
            LyricsPane()
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @ObservedObject var selection: PaneSelection
    @ObservedObject private var fx = AudioEffects.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            wordmark
            nav
            Spacer(minLength: Space.lg)
            engineState
        }
        .padding(Space.lg)
        // Room for the traffic lights: the titlebar is transparent and the
        // content view runs full height behind it.
        .padding(.top, Space.xl)
        .frame(width: 248)
        .background(SP.bgColor)
    }

    private var wordmark: some View {
        BrandLockup(height: 19)
            .padding(.horizontal, Space.sm)
    }

    private var nav: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ForEach(AppPane.allCases) { pane in
                let selected = selection.pane == pane
                Button {
                    withAnimation(Motion.state) { selection.pane = pane }
                } label: {
                    HStack(spacing: Space.md) {
                        Image(systemName: pane.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected ? SP.accent : SP.textTertiary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pane.title)
                                .font(Typo.label)
                                .foregroundStyle(selected ? SP.textPrimary : SP.textSecondary)
                            Text(pane.blurb)
                                .font(Typo.caption)
                                .foregroundStyle(SP.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.md)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.control)
                            .fill(selected ? Color.white.opacity(0.07) : .clear)
                    )
                    // Selection is marked by the leading bar and the icon tint,
                    // not by colour alone.
                    .overlay(alignment: .leading) {
                        if selected {
                            Capsule()
                                .fill(SP.accent)
                                .frame(width: 2, height: 20)
                                .padding(.leading, 2)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: Radius.control))
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
    }

    private var engineState: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: fx.engineRunning ? "dot.radiowaves.left.and.right" : "pause.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(fx.engineRunning ? SP.accent : SP.textTertiary)
            Text(fx.engineRunning ? "Engine live" : "Engine off")
                .font(Typo.caption)
                .foregroundStyle(fx.engineRunning ? SP.accent : SP.textTertiary)
            Spacer()
        }
        .padding(.horizontal, Space.sm)
    }
}
