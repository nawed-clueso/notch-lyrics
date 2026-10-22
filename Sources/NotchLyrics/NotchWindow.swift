import AppKit
import SwiftUI

/// Borderless, non-activating, always-on-top panel that paints into the menu bar strip.
final class NotchWindow: NSPanel {
    private var passthroughTimer: Timer?
    private var spaceObserver: NSObjectProtocol?
    private var scrollMonitor: Any?
    /// Scroll distance not yet turned into a whole-line skim.
    private var skimAccumulator: CGFloat = 0
    private let state: PlaybackState
    /// Per-display sizing; rebuilt on reposition since the collapsed cap
    /// depends on the display's current width.
    private var layout: NotchLayout
    private var host: PillHostingView<NotchPillView>!
    init(state: PlaybackState, screen: NSScreen = NotchGeometry.primaryScreen) {
        self.state = state
        self.layout = NotchGeometry.layout(for: screen)
        let frame = NotchGeometry.windowFrame(on: screen)
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        // `.stationary` can cause status-bar-level panels to hide-on-switch
        // on some macOS versions; dropping it makes the window genuinely
        // follow every Space.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = false
        isMovable = false
        hidesOnDeactivate = false

        // Re-assert the window when the user switches Spaces — accessory
        // panels occasionally lose their front-most position across switches.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.orderFrontRegardless() }
        }

        let host = PillHostingView(rootView: NotchPillView(state: state, layout: layout))
        self.host = host
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        // Only the pill's actual rect accepts clicks; everything else in the window
        // passes through to the app below.
        host.liveHitRect = { [weak self, weak host, weak state] in
            guard let self, let host, let state else { return .zero }
            let layout = self.layout
            let bounds = host.bounds
            // Match the closed bar's live width (it follows the lyric) so
            // the click pass-through region tracks the visible shape.
            let w = state.isHovering ? layout.expandedWidth : state.collapsedBar(for: layout).totalWidth
            let h: CGFloat = state.isHovering
                ? CardMetrics.height(state: state, layout: layout)
                : layout.barHeight
            // Mirrors NotchLayout.anchor (.top): centred horizontally, top
            // edge at bounds.maxY on every display.
            return NSRect(x: bounds.midX - w / 2, y: bounds.maxY - h, width: w, height: h)
        }
        contentView = host

        // Hit-test-returning-nil isn't always enough on recent macOS to make
        // clicks pass through to apps below — the panel still intercepts at
        // the window level. We poll the cursor position and flip
        // `ignoresMouseEvents` so the entire panel becomes transparent to
        // mouse input whenever the cursor is outside the visible pill rect.
        // 60Hz keeps the dead window (≤16ms) below human reaction time, so the
        // cursor reliably "warms up" the pill before any click lands.
        passthroughTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePassThrough() }
        }
        RunLoop.main.add(passthroughTimer!, forMode: .common)

        // Two-finger scroll over the open card skims the lyrics a line at a
        // time. Local monitor: the panel receives the events only while the
        // cursor is over the card, which is exactly when skimming applies.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, event.window === self else { return false }
                return self.handleSkimScroll(event)
            }
            return consumed ? nil : event
        }
        updatePassThrough()
    }


    /// Re-apply placement after a display reconfiguration (resolution change,
    /// monitors rearranged). `syncWindowsToScreens` only adds and removes windows,
    /// so without this an existing window keeps a stale — no longer centred — frame.
    @MainActor
    func reposition(on screen: NSScreen) {
        layout = NotchGeometry.layout(for: screen)
        host.rootView = NotchPillView(state: state, layout: layout)
        setFrame(NotchGeometry.windowFrame(on: screen), display: true)
    }

    /// Turns scrolling into line steps. Returns true when it consumed the event.
    @MainActor
    private func handleSkimScroll(_ event: NSEvent) -> Bool {
        guard state.isHovering, state.isMusic, state.lyricsAreSynced else { return false }
        // Momentum after the fingers lift would race through the song.
        guard event.momentumPhase.isEmpty else { return true }
        if event.phase == .began { skimAccumulator = 0 }
        // Trackpads report points; a mouse wheel reports lines, so scale those.
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        skimAccumulator += delta
        let threshold: CGFloat = 26
        while abs(skimAccumulator) >= threshold {
            // Fingers moving up (content scrolling up) reads as moving later
            // in the song, as when scrolling down a page of lyrics.
            let step = skimAccumulator < 0 ? 1 : -1
            state.skim(lines: step)
            skimAccumulator += CGFloat(step) * threshold
        }
        return true
    }

    @MainActor
    private func updatePassThrough() {
        guard let host = contentView as? PillHostingViewType,
              let getRect = host.liveHitRect else { return }
        let pillInHost = getRect()
        // Pad the activation zone by 12px on each side so that a moving
        // cursor activates mouse handling slightly *before* it reaches the
        // visible pill rect. Without this padding a fast right-click can
        // race the 30Hz timer and the click goes to the app below.
        let pad: CGFloat = 12
        let screenRect = NSRect(
            x: frame.origin.x + pillInHost.origin.x - pad,
            y: frame.origin.y + pillInHost.origin.y - pad,
            width: pillInHost.width + pad * 2,
            height: pillInHost.height + pad * 2
        )
        let mouse = NSEvent.mouseLocation
        let inside = NSPointInRect(mouse, screenRect)
        let shouldIgnore = !inside
        if ignoresMouseEvents != shouldIgnore {
            ignoresMouseEvents = shouldIgnore
        }

        // Hover intent uses the visible shape, not the padded activation zone.
        // The closed bar sits at the very top of the display, so the rect is
        // extended up past the screen edge: a cursor pushed into the top edge
        // still counts as over it.
        var visible = pillInHost.offsetBy(dx: frame.origin.x, dy: frame.origin.y)
        visible.size.height += 2
        HoverIntent.shared.report(self, inside: NSPointInRect(mouse, visible), state: state)
    }

    /// The frame deliberately overlaps the menu bar and the notch; never let
    /// AppKit nudge it down out of them.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // Must be true so SwiftUI buttons inside can receive clicks. The .nonactivatingPanel
    // style mask keeps the panel from stealing focus from the active app.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Opens the pill when the cursor rests on it and closes it once the cursor
/// has been away for a moment.
///
/// Both delays are there to read intent. The closed bar sits in the menu bar,
/// so the cursor crosses it on the way to menus and status items; opening only
/// after a short rest stops those passes from popping the card. Closing after a
/// grace period lets the cursor slip off the card's edge and back without it
/// collapsing under you.
///
/// Every display's window reports here and the playback state is shared, so
/// the pill counts as hovered while the cursor is over any of them.
@MainActor
final class HoverIntent {
    static let shared = HoverIntent()

    static let openDelay: TimeInterval = 0.18
    static let closeDelay: TimeInterval = 0.35

    private var insideWindows: Set<ObjectIdentifier> = []
    private var enteredAt: Date?
    private var leftAt: Date?

    func report(_ window: NSWindow, inside: Bool, state: PlaybackState) {
        let id = ObjectIdentifier(window)
        if inside { insideWindows.insert(id) } else { insideWindows.remove(id) }

        let now = Date()
        if !insideWindows.isEmpty {
            leftAt = nil
            let since = enteredAt ?? now
            enteredAt = since
            // Not mid-drag: a drag across the menu bar isn't a hover.
            if !state.isHovering,
               NSEvent.pressedMouseButtons == 0,
               now.timeIntervalSince(since) >= Self.openDelay {
                state.isHovering = true
            }
        } else {
            enteredAt = nil
            let since = leftAt ?? now
            leftAt = since
            // Never mid-drag: a scrub that wanders off the card keeps it open.
            if state.isHovering, NSEvent.pressedMouseButtons == 0,
               now.timeIntervalSince(since) >= Self.closeDelay {
                state.isHovering = false
            }
        }
    }
}
