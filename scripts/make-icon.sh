#!/usr/bin/env bash
# Render 🪩 as an .icns at every macOS-required size.
#
# The logo *is* the emoji, so there is no vector artwork to maintain — Apple
# Color Emoji is drawn at each size and downsampled from a 2x buffer.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICONSET="/tmp/notch-lyrics-icon.iconset"
OUT="$ROOT/scripts/AppIcon.icns"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

swift - <<'SWIFT'
import AppKit

let emoji = "🪩"
let dir = "/tmp/notch-lyrics-icon.iconset"

func render(size: Int, scale: Int) {
    let pt = size * scale
    let image = NSImage(size: NSSize(width: pt, height: pt))
    image.lockFocus()
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pt, height: pt).fill()
    // 0.82 leaves the margin macOS expects around a Dock icon.
    let font = NSFont.systemFont(ofSize: CGFloat(pt) * 0.82)
    let para = NSMutableParagraphStyle(); para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
    let str = NSAttributedString(string: emoji, attributes: attrs)
    let strSize = str.size()
    let origin = NSPoint(
        x: (CGFloat(pt) - strSize.width) / 2,
        y: (CGFloat(pt) - strSize.height) / 2 - CGFloat(pt) * 0.04
    )
    str.draw(at: origin)
    image.unlockFocus()

    let suffix = scale == 1 ? "" : "@2x"
    let path = "\(dir)/icon_\(size)x\(size)\(suffix).png"
    if let tiff = image.tiffRepresentation,
       let bmp = NSBitmapImageRep(data: tiff),
       let png = bmp.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

for s in [16, 32, 128, 256, 512] { render(size: s, scale: 1); render(size: s, scale: 2) }
SWIFT

iconutil -c icns "$ICONSET" -o "$OUT"
echo "✓ $OUT"
