import SwiftUI

/// The identity: the mirrorball emoji plus the name set in the title serif.
///
/// This replaces a hand-drawn faceted-ball mark. The emoji is the logo — it
/// carries the disco read at every size, needs no asset pipeline, and renders
/// from the system font, so the wordmark is the only thing we typeset.
struct BrandLockup: View {
    /// Cap height of the wordmark; the emoji is sized in proportion.
    var height: CGFloat = 20
    var colour: Color = SP.textPrimary

    var body: some View {
        HStack(spacing: height * 0.42) {
            Text(verbatim: "🪩")
                // Emoji glyphs sit high in their box, so nudge down to sit on
                // the wordmark's baseline rather than above it.
                .font(.system(size: height * 1.25))
                .offset(y: height * 0.06)
            Text("Notch Lyrics")
                .font(.custom(AppFont.titleSerif, size: height * 1.35))
                .foregroundStyle(colour)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Notch Lyrics")
    }
}

/// Emoji-only mark, for tight spots where the name is already obvious.
struct Brandmark: View {
    var size: CGFloat = 18

    var body: some View {
        Text(verbatim: "🪩")
            .font(.system(size: size))
            .accessibilityHidden(true)
    }
}
