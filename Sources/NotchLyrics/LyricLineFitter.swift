import AppKit

/// Breaks a lyric line into the rows it will occupy at a given width, shrinking
/// the type a point at a time until it fits in `maxLines`.
///
/// The open card draws each row as its own single-line `Text`, so the breaks
/// here are the breaks on screen. That is what lets the sung-line fill finish
/// row one before starting row two; a wrapped `Text` gives no way to know
/// where it broke.
@MainActor
enum LyricLineFitter {
    struct Line: Equatable {
        let text: String
        /// Rendered width in points.
        let width: CGFloat
        /// True for a last row that still overflows at the minimum size and is
        /// left for `Text` to end with an ellipsis.
        let truncated: Bool
    }

    struct Fit: Equatable {
        let size: CGFloat
        let lines: [Line]
    }

    /// `tracking` is letter spacing as a fraction of the point size, matching
    /// what the row is drawn with.
    static func fit(_ text: String, fontName: String, tracking: CGFloat = 0,
                    maxSize: CGFloat, minSize: CGFloat,
                    width: CGFloat, maxLines: Int) -> Fit {
        let key = "\(fontName)|\(tracking)|\(maxSize)|\(minSize)|\(width)|\(maxLines)|\(text)"
        if let hit = cache[key] { return hit }

        var size = maxSize
        var lines = breakLines(text, fontName: fontName, tracking: tracking, size: size, width: width)
        while lines.count > maxLines, size - 1 >= minSize {
            size -= 1
            lines = breakLines(text, fontName: fontName, tracking: tracking, size: size, width: width)
        }
        if lines.count > maxLines {
            let head = Array(lines.prefix(maxLines - 1))
            let rest = lines.dropFirst(maxLines - 1).map(\.text).joined(separator: " ")
            lines = head + [Line(text: rest, width: width, truncated: true)]
        }

        let result = Fit(size: size, lines: lines)
        if cache.count > 64 { cache.removeAll() }
        cache[key] = result
        return result
    }

    private static var cache: [String: Fit] = [:]

    private static func breakLines(_ text: String, fontName: String, tracking: CGFloat,
                                   size: CGFloat, width: CGFloat) -> [Line] {
        let font = NSFont(name: fontName, size: size) ?? .systemFont(ofSize: size)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: size * tracking]
        let storage = NSTextStorage(string: text, attributes: attrs)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byWordWrapping
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)

        let ns = text as NSString
        var lines: [Line] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, glyphs, _ in
            let chars = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let piece = ns.substring(with: chars).trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { return }
            // Measure the trimmed row itself: the fragment's used rect can
            // include the trailing space the break happened on.
            let w = ceil((piece as NSString).size(withAttributes: attrs).width)
            lines.append(Line(text: piece, width: min(w, width), truncated: false))
        }
        return lines
    }
}
