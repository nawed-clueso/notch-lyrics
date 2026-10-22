import AppKit
import SwiftUI

/// Per-display sizing and anchoring for the pill.
///
/// The pill is centred on the notch and grows out of it: closed, it is the
/// notch widened by an equal wing on each side, flush with the top of the
/// display; open, it drops down from the notch as a card. A display without a
/// notch gets a zero-width "virtual notch" at its midpoint, so the same shape
/// hangs from the centre of the menu bar.
struct NotchLayout {
    let hasNotch: Bool
    let expandedWidth: CGFloat
    /// Tallest the open card's body can get, below the notch-height bar.
    /// Sizes the window; the card itself is sized to its content.
    let expandedMusicH: CGFloat
    let expandedVideoH: CGFloat
    /// Corner radius of the open card's bottom corners.
    let expandedRadius: CGFloat
    /// Type/padding multiplier for the closed bar. Stays at 1.0 so the bar
    /// keeps menu-bar proportions.
    let collapsedScale: CGFloat
    /// Type/padding multiplier for the open card.
    let expandedScale: CGFloat

    /// Width of the physical notch; 0 on a display without one. Filled in by
    /// `NotchGeometry.layout(for:)`.
    var notchWidth: CGFloat = 0
    /// Height of the closed bar: the notch's height, or the menu bar's.
    var barHeight: CGFloat = 24
    /// Widest either wing may grow before its text truncates. Equal on both
    /// sides, so it is bounded by the narrower free span either side of the notch.
    var maxWing: CGFloat = 0

    /// Outward curve where the shape's top corners meet the menu bar, as on
    /// the real notch. Part of the shape's frame on both sides.
    static let flare: CGFloat = 6

    /// Built-in notched display.
    static let notched = NotchLayout(
        hasNotch: true,
        expandedWidth: 560,
        expandedMusicH: 190,
        expandedVideoH: 112,
        expandedRadius: 20,
        collapsedScale: 1.0,
        expandedScale: 1.0
    )

    /// No notch: the same bar hanging from the menu bar's centre, opening into
    /// a ~1.2× card that uses the bigger display.
    static let topRight = NotchLayout(
        hasNotch: false,
        expandedWidth: 650,
        expandedMusicH: 230,
        expandedVideoH: 140,
        expandedRadius: 24,
        collapsedScale: 1.0,
        expandedScale: 1.2
    )

    /// The window is sized to the open card (the widest and tallest state), so
    /// the SwiftUI inside can grow without resizing the window itself.
    var windowSize: CGSize { CGSize(width: expandedWidth, height: barHeight + expandedMusicH) }

    /// The pill is centred horizontally and pinned to the top of its window;
    /// the window itself is centred on the notch.
    var anchor: Alignment { .top }

    /// Scales a base point size for the expanded card.
    func pt(_ size: CGFloat) -> CGFloat { (size * expandedScale).rounded() }
    /// Scales a base point size for the collapsed bar.
    func cpt(_ size: CGFloat) -> CGFloat { (size * collapsedScale).rounded() }
}

/// Resolves placement for the borderless pill window on a given display.
enum NotchGeometry {
    static var primaryScreen: NSScreen {
        NSScreen.main ?? NSScreen.screens.first!
    }

    /// True only on physically-notched displays.
    ///
    /// `safeAreaInsets.top > 0` is much more reliable than `auxiliaryTopLeftArea`
    /// alone — that property exists on some external monitors too and returns
    /// surprising values.
    static func hasNotch(_ screen: NSScreen) -> Bool {
        if #available(macOS 12.0, *) {
            return screen.safeAreaInsets.top > 0 && screen.auxiliaryTopLeftArea != nil
        }
        return false
    }

    /// Menu-bar room kept clear at each end of the display: the Apple menu and
    /// the frontmost app's name on the left, the clock and status items on the
    /// right.
    static let leftReserve: CGFloat = 140
    static let rightReserve: CGFloat = 160

    static func layout(for screen: NSScreen) -> NotchLayout {
        var layout: NotchLayout = hasNotch(screen) ? .notched : .topRight
        let notch = notchSpan(on: screen)
        layout.notchWidth = notch.width
        layout.barHeight = barHeight(on: screen)
        // Equal wings, so the narrower side sets the cap; and never wider than
        // the open card, so opening never makes the shape narrower.
        let freeLeft = notch.minX - screen.frame.minX - leftReserve
        let freeRight = screen.frame.maxX - notch.maxX - rightReserve
        let cardWing = (layout.expandedWidth - notch.width) / 2 - NotchLayout.flare
        layout.maxWing = max(60, min(freeLeft, freeRight, cardWing).rounded(.down))
        return layout
    }

    /// Horizontal span of the notch in screen coordinates; zero width at the
    /// display's midpoint when there is no notch.
    static func notchSpan(on screen: NSScreen) -> (minX: CGFloat, maxX: CGFloat, width: CGFloat) {
        if hasNotch(screen),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            return (left.maxX, right.minX, right.minX - left.maxX)
        }
        let mid = screen.frame.midX
        return (mid, mid, 0)
    }

    /// The notch's height on a notched display, otherwise the menu bar's.
    static func barHeight(on screen: NSScreen) -> CGFloat {
        if hasNotch(screen) { return screen.safeAreaInsets.top }
        // visibleFrame excludes the menu bar when it is showing; when it
        // auto-hides the difference is 0, so fall back to the standard height.
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return menuBar > 0 ? menuBar : NSStatusBar.system.thickness + 2
    }

    /// Centred on the notch (or the display's midpoint) and flush with the top
    /// edge, so the closed bar reads as the notch itself grown wider.
    static func windowFrame(on screen: NSScreen) -> NSRect {
        let layout = layout(for: screen)
        let size = layout.windowSize
        let notch = notchSpan(on: screen)
        let centreX = notch.minX + notch.width / 2
        let x = (centreX - size.width / 2).rounded()
        let y = screen.frame.maxY - size.height
        NSLog("📐 windowFrame (\(layout.hasNotch ? "notch" : "virtual notch")) for \(screen.localizedName): origin=(\(x), \(y)) notchWidth=\(notch.width) bar=\(layout.barHeight)")
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
