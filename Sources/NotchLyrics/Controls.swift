import SwiftUI

// MARK: - Sizes
//
// Small 32, medium 40, large 48 — the standard three. Height is set explicitly
// rather than falling out of padding so rows of mixed controls line up.

enum ControlSize {
    case small, medium

    var height: CGFloat { self == .small ? 32 : 40 }
    var hPadding: CGFloat { self == .small ? Space.md : Space.xl }
    var font: Font { self == .small ? Typo.label : Typo.button }
}

// MARK: - Style scaffolding
//
// Hover and pressed each step the fill along the neutral scale. ButtonStyle
// can see `isPressed` but not hover, so the label lives in a small view that
// owns the hover state. The system focus effect is left enabled and the content
// shape is set to match, so the ring traces the control's real silhouette.

private struct StyledLabel<S: InsettableShape>: View {
    let configuration: ButtonStyleConfiguration
    let shape: S
    let size: ControlSize
    let foreground: Color
    /// Fills for rest, hover and pressed.
    let fills: (rest: Color, hover: Color, pressed: Color)
    let border: Color?

    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(foreground)
            .padding(.horizontal, size.hPadding)
            .frame(height: size.height)
            .background(shape.fill(fill))
            .overlay { if let border { shape.strokeBorder(border) } }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed && !Motion.reduced ? 0.97 : 1)
            .animation(Motion.floating, value: configuration.isPressed)
            .animation(Motion.state, value: hovering)
            .onHover { hovering = $0 }
    }

    private var fill: Color {
        if configuration.isPressed { return fills.pressed }
        return hovering ? fills.hover : fills.rest
    }
}

// MARK: - Primary
//
// One per view. Solid accent when it is the action to take; the neutral variant
// is for when the same control now means "undo the thing" and shouldn't keep
// shouting.

struct PrimaryButtonStyle: ButtonStyle {
    var filled: Bool = true
    var size: ControlSize = .medium

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(
            configuration: configuration,
            shape: Capsule(),
            size: size,
            foreground: filled ? .black : SP.textPrimary,
            fills: filled
                ? (SP.accent, SP.accent.opacity(0.88), SP.accent.opacity(0.78))
                : (Color.white.opacity(0.10), Color.white.opacity(0.16), Color.white.opacity(0.20)),
            border: filled ? nil : SP.divider
        )
    }
}

// MARK: - Secondary

struct SecondaryButtonStyle: ButtonStyle {
    var size: ControlSize = .medium

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(
            configuration: configuration,
            shape: Capsule(),
            size: size,
            foreground: SP.textPrimary,
            fills: (Color.white.opacity(0.08), Color.white.opacity(0.14), Color.white.opacity(0.18)),
            border: SP.divider
        )
    }
}

// MARK: - Tertiary

/// Low emphasis: transparent until hovered. For "Flatten EQ", "Skip Setup".
struct TertiaryButtonStyle: ButtonStyle {
    var size: ControlSize = .small

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(
            configuration: configuration,
            shape: Capsule(),
            size: size,
            foreground: SP.textSecondary,
            fills: (.clear, Color.white.opacity(0.08), Color.white.opacity(0.12)),
            border: nil
        )
    }
}

// MARK: - Chip

/// Segmented pill for a small set of exclusive options.
struct ChipButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(
            configuration: configuration,
            shape: Capsule(),
            size: .small,
            foreground: selected ? .black : SP.textSecondary,
            fills: selected
                ? (SP.accent, SP.accent.opacity(0.88), SP.accent.opacity(0.78))
                : (Color.white.opacity(0.06), Color.white.opacity(0.12), Color.white.opacity(0.16)),
            border: selected ? nil : SP.divider
        )
    }
}

// MARK: - Icon

/// Square icon-only control. Always pair with `.help(_:)` — an icon alone is
/// not a label.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconLabel(configuration: configuration)
    }

    private struct IconLabel: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(SP.textSecondary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control)
                        .fill(configuration.isPressed ? Color.white.opacity(0.16)
                              : (hovering ? Color.white.opacity(0.12) : Color.white.opacity(0.06)))
                )
                .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(SP.divider))
                .contentShape(RoundedRectangle(cornerRadius: Radius.control))
                .animation(Motion.state, value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - Mini

/// Inline action inside a status row, where a medium control would dominate.
struct MiniButtonStyle: ButtonStyle {
    var filled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(
            configuration: configuration,
            shape: Capsule(),
            size: .small,
            foreground: filled ? .black : SP.textPrimary,
            fills: filled
                ? (SP.accent, SP.accent.opacity(0.88), SP.accent.opacity(0.78))
                : (Color.white.opacity(0.10), Color.white.opacity(0.16), Color.white.opacity(0.20)),
            border: filled ? nil : SP.divider
        )
    }
}

// MARK: - Pressable

/// For controls that draw their own surface (preset cards, nav rows) and only
/// want the press response.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduced ? 0.97 : 1)
            .animation(Motion.floating, value: configuration.isPressed)
    }
}
