import AppKit
import SwiftUI

// MARK: - Palette
//
// Two families do the work: neutral grays rank information, the accent signals
// state and the single primary action per view. Gray steps encode intent, so
// don't reach for a surface tone as a text colour or vice versa.

enum SP {
    // Structure
    static let bg            = NSColor(red: 0.071, green: 0.071, blue: 0.071, alpha: 1)
    static let bgColor       = Color(red: 0.071, green: 0.071, blue: 0.071)   // window
    static let surface       = Color(red: 0.094, green: 0.094, blue: 0.094)   // card
    static let surfaceHi     = Color(red: 0.141, green: 0.141, blue: 0.141)   // well inside a card
    static let surfaceTop    = Color(red: 0.165, green: 0.165, blue: 0.165)   // raised
    static let divider       = Color(white: 1.0, opacity: 0.06)

    // Meaning
    static let accent        = Color(red: 0.118, green: 0.843, blue: 0.376)   // #1ED760
    /// Mirrorball highlight. Identity only — not a UI state colour.
    static let glint         = Color(red: 0.784, green: 1.0, blue: 0.867)      // #C8FFDD
    static let warning       = Color(red: 1.0, green: 0.694, blue: 0.196)
    static let danger        = Color(red: 1.0, green: 0.42, blue: 0.35)

    // Text ranks. Tertiary is 0.58 rather than 0.45 so helper copy still clears
    // WCAG AA (4.5:1) against `surface`; 0.45 measured 3.7:1 and failed.
    static let textPrimary   = Color.white
    static let textSecondary = Color(white: 0.72)
    static let textTertiary  = Color(white: 0.58)
    /// Decorative or disabled only — deliberately below AA, never for content.
    static let textDisabled  = Color(white: 0.38)
}

// MARK: - Spacing
//
// One 4px scale, applied with a three-step rhythm: `sm` inside a group,
// `lg` between groups, `section` between sections. Nothing off-scale.

enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let section: CGFloat = 40
}

// MARK: - Radius
//
// One family per view: controls and wells at `control`, cards and popovers at
// `card`, window-scale surfaces at `sheet`, pills for buttons.

enum Radius {
    static let control: CGFloat = 6
    static let card: CGFloat = 12
    static let sheet: CGFloat = 16
}

// MARK: - Typography
//
// Two weights only — `.regular` for prose, `.semibold` for anything that ranks
// or labels. Size and colour carry the rest. Values use monospaced digits so
// readouts don't jitter as numbers change.

enum Typo {
    /// Pane title, set in the serif. It carries the formality, so it is used
    /// sparingly — one per pane — and never for controls.
    static func title(_ size: CGFloat = 30) -> Font {
        .custom(AppFont.titleSerif, size: size)
    }
    /// Section heading inside a pane. Sans, not serif: at 15pt the serif's
    /// contrast turns spindly, and headings sit next to controls.
    static let heading = Font.custom(AppFont.bodySemibold, size: 15)
    /// Single-line scannable content: nav, form labels, metadata.
    static let label = Font.custom(AppFont.bodySemibold, size: 12)
    /// All-caps micro label above a control.
    static let micro = Font.custom(AppFont.bodySemibold, size: 10)
    /// Multi-line body text.
    static let copy = Font.custom(AppFont.bodyRegular, size: 13)
    /// Helper and secondary copy.
    static let caption = Font.custom(AppFont.bodyRegular, size: 11)
    /// Control labels.
    static let button = Font.custom(AppFont.bodySemibold, size: 13)
    /// Readouts, values, shell commands.
    static let mono = Font.custom(AppFont.monoRegular, size: 11).monospacedDigit()
    static let monoSmall = Font.custom(AppFont.monoRegular, size: 10).monospacedDigit()
}

// MARK: - Motion
//
// Motion only where it clarifies a change, and never when the user has asked
// the system for less of it.

enum Motion {
    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// ~150ms state change.
    static var state: Animation? { reduced ? nil : .easeOut(duration: 0.15) }
    /// ~200ms floating element.
    static var floating: Animation? { reduced ? nil : .spring(response: 0.28, dampingFraction: 0.86) }
    /// ~300ms overlay or pane transition.
    static var overlay: Animation? { reduced ? nil : .easeInOut(duration: 0.3) }
}

// MARK: - Surfaces

extension View {
    /// Standard card: tonal surface plus a hairline border. Hierarchy comes from
    /// tone and border; shadows are reserved for popovers and modals.
    func card(padding: CGFloat = Space.xl,
              fill: Color = SP.surface,
              radius: CGFloat = Radius.card) -> some View {
        self
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(SP.divider))
    }

    /// Inset control well inside a card.
    func well(padding: CGFloat = Space.md,
              radius: CGFloat = Radius.control) -> some View {
        self
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius).fill(SP.surfaceHi))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(SP.divider))
    }
}
