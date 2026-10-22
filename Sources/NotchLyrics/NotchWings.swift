import AppKit

/// Lays out the closed bar: the notch widened by one wing on each side.
///
/// The bar has to stay centred on the notch, so both wings are always the same
/// width. Putting the whole lyric on one side would leave the other wing as
/// empty black of the same size, so the line is split instead: it breaks at
/// the word boundary that best balances the two halves, the first half ends
/// against the left of the camera and the rest carries on to its right. Each
/// wing is then only about half a line wide.
@MainActor
enum NotchWings {
    struct Bar: Equatable {
        let left: String
        let right: String
        /// Width of each wing, excluding the notch and the top-corner flares.
        let wing: CGFloat
        /// Full width of the shape: notch, both wings and both flares.
        let totalWidth: CGFloat
    }

    // Wing anatomy, outer edge to notch:
    //   left:  edgePad | artwork | innerGap | text | notchGap | notch
    //   right: notch | notchGap | text | innerGap | meter | edgePad
    static let fontSize: CGFloat = 11
    static let edgePad: CGFloat = 10
    static let innerGap: CGFloat = 8
    static let meterWidth: CGFloat = 15

    /// Gap between the text and the camera. With no physical notch the two
    /// halves meet at the centre, so it shrinks to a word space.
    static func notchGap(_ layout: NotchLayout) -> CGFloat {
        layout.notchWidth > 0 ? 8 : 2
    }

    static func artSize(_ layout: NotchLayout) -> CGFloat {
        min(20, layout.barHeight - 8)
    }

    static func bar(for text: String, layout: NotchLayout) -> Bar {
        let key = "\(layout.notchWidth)|\(layout.barHeight)|\(layout.maxWing)|\(text)"
        if let hit = cache[key] { return hit }

        let (left, right) = split(text)
        let gap = notchGap(layout)
        // +2 per text run: SwiftUI's line can come out a hair wider than
        // NSString measures it, and an early ellipsis looks like a bug.
        let leftText = left.isEmpty ? 0 : width(of: left) + 2
        let rightText = right.isEmpty ? 0 : width(of: right) + 2
        let leftNeed = edgePad + artSize(layout) + innerGap + leftText + gap
        let rightNeed = gap + rightText + innerGap + meterWidth + edgePad
        let wing = min(max(leftNeed, rightNeed).rounded(.up), layout.maxWing)
        let total = layout.notchWidth + wing * 2 + NotchLayout.flare * 2

        let bar = Bar(left: left, right: right, wing: wing, totalWidth: total)
        if cache.count > 64 { cache.removeAll() }
        cache[key] = bar
        return bar
    }

    private static var cache: [String: Bar] = [:]

    /// A line too long for the wings at their cap, broken into runs of words
    /// that each fit without truncating. The closed bar shows them in turn as
    /// the line is sung, so no words are lost to an ellipsis in the middle.
    /// A line that fits comes back as one page.
    static func pages(for text: String, layout: NotchLayout) -> [String] {
        let key = "\(layout.notchWidth)|\(layout.barHeight)|\(layout.maxWing)|\(text)"
        if let hit = pageCache[key] { return hit }

        let words = text.split(separator: " ").map(String.init)
        var pages: [String] = []
        var current: [String] = []
        for word in words {
            let candidate = (current + [word]).joined(separator: " ")
            if current.isEmpty || fits(candidate, layout: layout) {
                current.append(word)
            } else {
                pages.append(current.joined(separator: " "))
                current = [word]
            }
        }
        if !current.isEmpty { pages.append(current.joined(separator: " ")) }
        if pages.isEmpty { pages = [text] }

        if pageCache.count > 64 { pageCache.removeAll() }
        pageCache[key] = pages
        return pages
    }

    private static var pageCache: [String: [String]] = [:]

    /// True when the balanced split of `text` fits both wings at their cap.
    private static func fits(_ text: String, layout: NotchLayout) -> Bool {
        let (left, right) = split(text)
        let gap = notchGap(layout)
        let leftRoom = layout.maxWing - edgePad - artSize(layout) - innerGap - gap
        let rightRoom = layout.maxWing - gap - innerGap - meterWidth - edgePad
        return width(of: left) + 2 <= leftRoom && width(of: right) + 2 <= rightRoom
    }

    /// Splits at the word break that minimises the wider half. One word stays
    /// whole on the left.
    private static func split(_ text: String) -> (String, String) {
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 1 else { return (words.first ?? "", "") }
        let space = width(of: " ")
        let widths = words.map { width(of: $0) }
        let total = widths.reduce(0, +) + space * CGFloat(words.count - 1)

        var best = 1
        var bestWidest = CGFloat.greatestFiniteMagnitude
        var leftWidth: CGFloat = 0
        for k in 1..<words.count {
            leftWidth += widths[k - 1] + (k > 1 ? space : 0)
            let rightWidth = total - leftWidth - space
            let widest = max(leftWidth, rightWidth)
            if widest < bestWidest {
                bestWidest = widest
                best = k
            }
        }
        return (words[..<best].joined(separator: " "), words[best...].joined(separator: " "))
    }

    private static func width(of s: String) -> CGFloat {
        let font = NSFont(name: AppFont.bodyRegular, size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize)
        return ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }
}
