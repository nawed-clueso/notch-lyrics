import AppKit
import SwiftUI

/// NSHostingView subclass with a custom hit-test rect. Areas outside the rect return
/// nil from hitTest(_:) so clicks fall through to whatever app's window is underneath.
/// This lets us keep a fixed-size NSPanel (sized to the expanded card) without
/// stealing clicks from the active app when the pill is collapsed.
/// Type-erased accessor so NotchWindow can read the live hit rect without
/// caring about the Content generic.
@MainActor
protocol PillHostingViewType: AnyObject {
    var liveHitRect: (() -> NSRect)? { get set }
}

final class PillHostingView<Content: View>: NSHostingView<Content>, PillHostingViewType {
    /// Returns the live hit rect in this view's coordinate space (origin bottom-left).
    /// Recomputed on every hit-test, so updating state.isHovering / state.isMusic
    /// immediately changes which area accepts clicks.
    var liveHitRect: (() -> NSRect)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let rect = liveHitRect?(), NSPointInRect(point, rect) {
            return super.hitTest(point)
        }
        return nil
    }
}
