import SwiftUI

/// The EQ response as a flat 2D plot, drawn natively.
///
/// This replaced a tilted Three.js surface. A response curve is read by
/// comparing heights against 0 dB, and perspective actively fights that — the
/// far end of a tilted plot is smaller than the near end, so equal boosts stop
/// looking equal. Flat, native, and on the same 4px grid as everything else.
struct EQCurveView: View {
    let bands: [Float]
    let preGain: Float
    let lowPass: Float
    let highPass: Float
    let bypass: Bool

    /// ±18 dB of band gain plus headroom for the filter skirts.
    private let range: Float = 24
    private static let hzMin: Float = 20
    private static let hzMax: Float = 22_050

    var body: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            let perDb = (size.height / 2 - 6) / CGFloat(range)

            // Grid: 0 dB solid, ±12 dB hairlines.
            for db in [Float(0), 12, -12] {
                var line = Path()
                let y = midY - CGFloat(db) * perDb
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(line, with: .color(db == 0 ? SP.divider.opacity(3) : SP.divider),
                           lineWidth: db == 0 ? 1 : 0.5)
            }

            // A tick per band, so the ten faders below map onto the picture.
            for hz in AudioEffects.bandFrequencies {
                let x = CGFloat(Self.unit(hz)) * size.width
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: size.height - 4))
                tick.addLine(to: CGPoint(x: x, y: size.height - 10))
                ctx.stroke(tick, with: .color(SP.textDisabled.opacity(0.5)), lineWidth: 1)
            }

            // The curve, sampled across the log-frequency axis.
            let steps = max(48, Int(size.width / 3))
            var curve = Path()
            var fill = Path()
            fill.move(to: CGPoint(x: 0, y: midY))
            for i in 0...steps {
                let u = Float(i) / Float(steps)
                let y = midY - CGFloat(response(atUnit: u)) * perDb
                let pt = CGPoint(x: CGFloat(u) * size.width, y: y)
                if i == 0 { curve.move(to: pt) } else { curve.addLine(to: pt) }
                fill.addLine(to: pt)
            }
            fill.addLine(to: CGPoint(x: size.width, y: midY))
            fill.closeSubpath()

            let tint = bypass ? SP.textDisabled : SP.accent
            ctx.fill(fill, with: .linearGradient(
                Gradient(colors: [tint.opacity(0.28), tint.opacity(0.04)]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))
            ctx.stroke(curve, with: .color(tint), lineWidth: 2)
        }
        .accessibilityLabel("Equaliser response curve")
        .accessibilityValue(summary)
    }

    private var summary: String {
        bypass ? "Bypassed"
               : "Pre-gain \(Int(preGain)) decibels, low-pass \(Int(lowPass)) hertz, high-pass \(Int(highPass)) hertz"
    }

    /// Position of a frequency on the log axis, 0…1.
    private static func unit(_ hz: Float) -> Float {
        let clamped = min(max(hz, hzMin), hzMax)
        return (log(clamped) - log(hzMin)) / (log(hzMax) - log(hzMin))
    }

    /// Approximate combined response in dB. Each parametric band contributes a
    /// bell centred on its own frequency; the filter corners add rolloff beyond
    /// them. Mirrors what the engine's EQ is actually doing closely enough to
    /// read as the same shape.
    private func response(atUnit u: Float) -> Float {
        guard !bypass else { return 0 }
        var db = preGain
        for (i, hz) in AudioEffects.bandFrequencies.enumerated() where i < bands.count {
            let gain = bands[i]
            if gain == 0 { continue }
            let d = u - Self.unit(hz)
            // ~0.5 octave bandwidth in the engine is about this wide here.
            db += gain * exp(-(d * d) / (2 * 0.055 * 0.055))
        }
        let lp = Self.unit(lowPass)
        if u > lp { db -= (u - lp) * 130 }
        let hp = Self.unit(highPass)
        if u < hp { db -= (hp - u) * 130 }
        return min(max(db, -range), range)
    }
}
