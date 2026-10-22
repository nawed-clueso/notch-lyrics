import AppKit
import SwiftUI

/// Extracts a small palette of dominant colors from an album artwork image.
/// Cheap: downsamples to 64×64 then buckets RGB into a coarse histogram. Picks the most
/// frequent buckets but rejects desaturated/near-black/near-white so the palette stays
/// visually interesting.
enum ColorExtractor {
    static func palette(from image: NSImage, count: Int = 5) -> [Color] {
        let target = NSSize(width: 64, height: 64)
        let small = NSImage(size: target)
        small.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target))
        small.unlockFocus()

        guard let tiff = small.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff)
        else { return Self.defaultPalette }

        var buckets: [Int: (count: Int, r: Double, g: Double, b: Double)] = [:]
        let w = bmp.pixelsWide, h = bmp.pixelsHigh
        for y in 0..<h {
            for x in 0..<w {
                guard let c = bmp.colorAt(x: x, y: y) else { continue }
                let r = Double(c.redComponent)
                let g = Double(c.greenComponent)
                let b = Double(c.blueComponent)
                // Reject near-greyscale and near-edges (white/black).
                let maxC = max(r, g, b), minC = min(r, g, b)
                let sat = maxC == 0 ? 0 : (maxC - minC) / maxC
                let val = maxC
                if sat < 0.18 || val < 0.15 || val > 0.95 { continue }
                // 4 bits per channel = 16 levels = 4096 buckets — fine grain at low cost.
                let rk = Int(r * 15.0)
                let gk = Int(g * 15.0)
                let bk = Int(b * 15.0)
                let key = (rk << 8) | (gk << 4) | bk
                var entry = buckets[key] ?? (0, 0, 0, 0)
                entry.count += 1
                entry.r += r; entry.g += g; entry.b += b
                buckets[key] = entry
            }
        }

        let sorted = buckets.values.sorted { $0.count > $1.count }
        let top = sorted.prefix(count * 3)   // grab extras so we can diversify

        // Diversify: skip buckets too close in hue to ones already picked.
        var picked: [(h: Double, s: Double, l: Double)] = []
        var output: [Color] = []
        for entry in top {
            let n = Double(entry.count)
            let r = entry.r / n, g = entry.g / n, b = entry.b / n
            let hsl = rgbToHSL(r: r, g: g, b: b)
            let tooClose = picked.contains { abs($0.h - hsl.h) < 0.07 && abs($0.s - hsl.s) < 0.2 }
            if tooClose { continue }
            picked.append(hsl)
            output.append(Color(red: r, green: g, blue: b))
            if output.count >= count { break }
        }
        return output.isEmpty ? Self.defaultPalette : padded(output, to: count)
    }

    /// A single dark, cover-aware solid colour for the panel background behind the
    /// white lyrics. Takes the dominant colour, keeps its hue but caps saturation
    /// and forces a low brightness so the text always stays legible — no gradient.
    static func backgroundColor(from image: NSImage) -> Color {
        let dominant = palette(from: image, count: 1).first ?? defaultPalette.first!
        let base = NSColor(dominant).usingColorSpace(.sRGB) ?? .black
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(NSColor(hue: h, saturation: min(s, 0.55), brightness: 0.20, alpha: 1))
    }

    static let defaultBackground = Color(red: 0.09, green: 0.09, blue: 0.11)

    static let defaultPalette: [Color] = [
        Color(red: 0.10, green: 0.10, blue: 0.12),
        Color(red: 0.16, green: 0.16, blue: 0.20),
        Color(red: 0.20, green: 0.18, blue: 0.30),
        Color(red: 0.12, green: 0.20, blue: 0.25),
        Color(red: 0.06, green: 0.06, blue: 0.10)
    ]

    private static func padded(_ colors: [Color], to count: Int) -> [Color] {
        guard colors.count < count else { return colors }
        var result = colors
        var i = 0
        while result.count < count {
            result.append(colors[i % colors.count])
            i += 1
        }
        return result
    }

    private static func rgbToHSL(r: Double, g: Double, b: Double) -> (h: Double, s: Double, l: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let l = (maxC + minC) / 2
        if maxC == minC { return (0, 0, l) }
        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: Double = 0
        if maxC == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if maxC == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        return (h / 6, s, l)
    }
}
