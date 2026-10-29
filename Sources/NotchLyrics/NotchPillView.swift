import SwiftUI
import AppKit

/// The pill, centred on the notch. Closed, it is the notch widened by an equal
/// wing on each side, with the current line split across the camera. Resting
/// the cursor on it (or clicking) drops it open into the lyrics card.
struct NotchPillView: View {
    @ObservedObject var state: PlaybackState
    let layout: NotchLayout

    var body: some View {
        let bar = state.collapsedBar(for: layout)
        let cardHeight = CardMetrics.height(state: state, layout: layout)
        ZStack(alignment: layout.anchor) {
            if ArtLooks.current.contains(.notchGlow), !state.isHovering,
               state.isMusic, state.artwork != nil {
                NotchGlow(color: ArtLooks.ink(state.palette), width: bar.totalWidth,
                          barHeight: layout.barHeight,
                          playing: state.nowPlaying?.isPlaying ?? false)
                    .transition(.opacity)
            }
            PillContent(state: state, layout: layout, bar: bar)
                .frame(
                    width: state.isHovering ? layout.expandedWidth : bar.totalWidth,
                    height: state.isHovering ? cardHeight : layout.barHeight
                )
                // Hover opens it (see HoverIntent); a click opens it without
                // waiting. It never closes on click, or the hover would just
                // reopen it under the cursor.
                .contentShape(Rectangle())
                .onTapGesture {
                    if !state.isHovering { state.isHovering = true }
                }
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: state.isHovering)
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: state.isMusic)
                // The card follows its content, growing when a line wraps.
                .animation(Motion.reduced ? nil : .spring(response: 0.36, dampingFraction: 0.86), value: cardHeight)
                // The wings follow the lyric, so they breathe a little per line.
                .animation(Motion.reduced ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: bar.wing)
        }
        .frame(width: layout.windowSize.width, height: layout.windowSize.height, alignment: layout.anchor)
    }
}

// MARK: - Pill body

private struct PillContent: View {
    @ObservedObject var state: PlaybackState
    let layout: NotchLayout
    let bar: NotchWings.Bar

    var body: some View {
        let open = state.isHovering
        // Closed, the bottom corners match the notch's own; open, the card's.
        let shape = NotchShape(
            flare: NotchLayout.flare,
            bottomRadius: open ? layout.expandedRadius : layout.barHeight * 0.32
        )
        ZStack {
            // Solid black while closed, so the bar reads as part of the notch;
            // the open card turns to frosted glass.
            ZStack(alignment: .top) {
                if open {
                    CardGlass(state: state)
                        .transition(.opacity)
                } else {
                    Color.black
                        .transition(.opacity)
                }
            }
            .clipShape(shape)
            .overlay {
                if open, ArtLooks.current.contains(.rim), state.isMusic, state.artwork != nil {
                    shape.stroke(AngularGradient(colors: state.palette + [state.palette.first ?? .white],
                                                 center: .center),
                                 lineWidth: 2)
                        .opacity(0.95)
                }
            }
            .shadow(color: .black.opacity(open ? 0.35 : 0), radius: 12, x: 0, y: 4)

            UnifiedContent(state: state, layout: layout, bar: bar, shape: shape)
        }
    }
}

/// The notch's silhouette at any width: flat top flush with the screen edge,
/// small outward curves where it meets the menu bar, rounded bottom corners.
struct NotchShape: Shape {
    var flare: CGFloat
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let f = min(flare, rect.width / 2, rect.height)
        let r = max(0, min(bottomRadius, (rect.width - 2 * f) / 2, rect.height - f))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + f, y: rect.minY + f),
                       control: CGPoint(x: rect.minX + f, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + f, y: rect.maxY - r))
        p.addArc(tangent1End: CGPoint(x: rect.minX + f, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.minX + f + r, y: rect.maxY), radius: r)
        p.addLine(to: CGPoint(x: rect.maxX - f - r, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX - f, y: rect.maxY),
                 tangent2End: CGPoint(x: rect.maxX - f, y: rect.maxY - r), radius: r)
        p.addLine(to: CGPoint(x: rect.maxX - f, y: rect.minY + f))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - f, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Glass

/// The open card's backdrop: frosted glass over whatever is behind the card,
/// with a faint wash of the cover's colour so it still belongs to the song,
/// then dimmed so busy windows behind it don't compete with the lyrics.
/// Idle and video (no artwork) get the dimmed glass alone.
private struct CardGlass: View {
    @ObservedObject var state: PlaybackState

    /// How much the dark layer over the glass hides what's behind the card.
    private static let dim = 0.35

    var body: some View {
        let look = ArtLooks.current
        ZStack {
            BehindWindowBlur()
            if state.isMusic, state.artwork != nil {
                state.backgroundColor
                    .opacity(0.22)
                    .transition(.opacity)
            }
            Color.black.opacity(Self.dim)
            if state.isMusic, let art = state.artwork {
                if look.contains(.glow) { GlowArt(image: art) }
                if look.contains(.vinyl) {
                    VinylArt(image: art, playing: state.nowPlaying?.isPlaying ?? false)
                }
                if look.contains(.rim) { RimSpill(color: ArtLooks.ink(state.palette)) }
            }
        }
        .animation(.easeInOut(duration: 0.4), value: state.backgroundColor)
    }
}

// MARK: - Cover-art looks (being chosen)

/// Treatments of the cover layered on the glass. Switchable while one is
/// picked; the rest get removed.
struct ArtLook: OptionSet {
    let rawValue: Int
    static let glow      = ArtLook(rawValue: 1 << 0)
    static let vinyl     = ArtLook(rawValue: 1 << 1)
    static let ink       = ArtLook(rawValue: 1 << 2)
    static let rim       = ArtLook(rawValue: 1 << 3)
    static let notchGlow = ArtLook(rawValue: 1 << 4)
}

@MainActor
enum ArtLooks {
    static var current: ArtLook = []

    /// The cover's most vivid colour, lifted so it reads on dark glass.
    static func ink(_ palette: [Color]) -> Color {
        let candidates = palette.compactMap { NSColor($0).usingColorSpace(.deviceRGB) }
        guard let best = candidates.max(by: {
            $0.saturationComponent * $0.brightnessComponent < $1.saturationComponent * $1.brightnessComponent
        }) else { return .white }
        return Color(hue: best.hueComponent,
                     saturation: min(best.saturationComponent, 0.7),
                     brightness: max(best.brightnessComponent, 0.92))
    }
}

/// The cover blurred to a faint glow behind the glass.
private struct GlowArt: View {
    let image: NSImage

    var body: some View {
        // Overlaid on a clear fill so the image's own size never feeds back
        // into the card's layout.
        Color.clear.overlay(
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: 50)
                .saturation(1.5)
                .opacity(0.55)
        )
        .clipped()
    }
}

/// The cover as a record label, half tucked off the card's right edge and
/// turning slowly while the track plays.
private struct VinylArt: View {
    let image: NSImage
    let playing: Bool

    var body: some View {
        GeometryReader { geo in
            let d = geo.size.height * 1.15
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing || Motion.reduced)) { context in
                    let angle = Motion.reduced ? 0 : context.date.timeIntervalSinceReferenceDate * 36
                    VinylDisc(image: image)
                        .rotationEffect(.degrees(angle.truncatingRemainder(dividingBy: 360)))
                }
                // The sheen stays put while the disc turns under it.
                Circle().fill(AngularGradient(colors: [.white.opacity(0), .white.opacity(0.10), .white.opacity(0),
                                                       .white.opacity(0.08), .white.opacity(0)],
                                              center: .center))
            }
            .frame(width: d, height: d)
            .position(x: geo.size.width - d * 0.12, y: geo.size.height * 0.56)
        }
        .opacity(0.85)
    }
}

private struct VinylDisc: View {
    let image: NSImage

    var body: some View {
        GeometryReader { geo in
            let d = geo.size.width
            ZStack {
                Circle().fill(Color(white: 0.08))
                ForEach(0..<12, id: \.self) { i in
                    Circle()
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                        .padding(d * 0.04 + CGFloat(i) * d * 0.017)
                }
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: d * 0.42, height: d * 0.42)
                    .clipShape(Circle())
                Circle().fill(Color.black).frame(width: d * 0.03, height: d * 0.03)
            }
        }
    }
}

/// Light spilling down from under the notch in the cover's colour.
private struct RimSpill: View {
    let color: Color

    var body: some View {
        RadialGradient(colors: [color.opacity(0.55), color.opacity(0)],
                       center: .top, startRadius: 0, endRadius: 260)
    }
}

/// A soft halo of the cover's colour under the closed bar, breathing while
/// music plays.
private struct NotchGlow: View {
    let color: Color
    let width: CGFloat
    let barHeight: CGFloat
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !playing || Motion.reduced)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breathe = playing && !Motion.reduced ? 0.75 + 0.25 * sin(t * 1.6) : 0.6
            Ellipse()
                .fill(color)
                .frame(width: width * 0.85, height: barHeight * 1.3)
                .blur(radius: 18)
                .opacity(0.85 * breathe)
                .offset(y: barHeight * 0.45)
        }
        .allowsHitTesting(false)
    }
}

/// A dark HUD material that blurs what's behind the window, not just what's
/// inside it. SwiftUI's `Material` only blends within the window, which in a
/// transparent panel has nothing to blur.
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        // The panel never becomes key, so force the active look or the
        // material renders flat and grey.
        view.state = .active
        // White lyrics need the dark variant whatever the system appearance.
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Unified content (closed bar, or the lyrics-first card)

private struct UnifiedContent: View {
    @ObservedObject var state: PlaybackState
    let layout: NotchLayout
    let bar: NotchWings.Bar
    let shape: NotchShape
    // Whether the card is in the view tree at all. It goes in and out with
    // animations disabled; only its opacity (`showExtras`) is animated.
    @State private var cardMounted = false
    // Drives whether the open card's content is mounted. We delay turning this
    // ON until the pill's open animation has had time to grow the frame, so
    // content doesn't pop in over a still-collapsing capsule. On close it flips
    // off immediately so content fades out as the pill shrinks.
    @State private var showExtras = false

    var body: some View {
        // Only opacity is animated here. Fading views in and out as they were
        // inserted and removed left frozen, half-faded copies of old lyrics
        // behind the card when a fade was cut short.
        ZStack(alignment: .top) {
            CollapsedRow(state: state, layout: layout, bar: bar)
                // Gone the moment the card starts opening, so the bar's lyric
                // doesn't hang beside the notch while the card's comes in.
                .opacity(state.isHovering ? 0 : 1)
                .animation(state.isHovering ? nil : .easeOut(duration: 0.18), value: state.isHovering)
                .allowsHitTesting(!state.isHovering)
            if cardMounted {
                // Laid out at the open size, so it never reflows as the frame
                // grows or shrinks, and clipped to the card.
                Color.clear.overlay(alignment: .top) {
                    ExpandedCard(state: state, layout: layout)
                        .padding(.horizontal, CardMetrics.inset(layout))
                        .padding(.bottom, layout.pt(12))
                        .frame(width: layout.expandedWidth,
                               height: CardMetrics.height(state: state, layout: layout),
                               alignment: .top)
                }
                .clipShape(shape)
                .opacity(state.isHovering && showExtras ? 1 : 0)
                .allowsHitTesting(state.isHovering && showExtras)
                .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: state.isHovering) { _, isOpen in
            if isOpen {
                setCardMounted(true)
                // Wait for the spring to mostly finish growing the frame before
                // fading the content in. 280ms is short of the spring's natural
                // settle so the fade-in overlaps the final easing of the open.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                    if state.isHovering {
                        withAnimation(.easeOut(duration: 0.18)) { showExtras = true }
                    }
                }
            } else {
                withAnimation(.easeOut(duration: 0.12)) { showExtras = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if !state.isHovering { setCardMounted(false) }
                }
            }
        }
    }

    private func setCardMounted(_ mounted: Bool) {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { cardMounted = mounted }
    }
}

// MARK: - Closed bar

/// Artwork and the first half of the line left of the camera, the rest of the
/// line and a level meter right of it. Both wings come from `NotchWings`, so
/// they are always equal and the bar stays centred.
private struct CollapsedRow: View {
    @ObservedObject var state: PlaybackState
    let layout: NotchLayout
    let bar: NotchWings.Bar

    var body: some View {
        if NotchWings.isWhole(layout) {
            wholeRow
        } else {
            splitRow
        }
    }

    /// No notch: the line in one piece, centred, between equal end caps.
    private var wholeRow: some View {
        let cap = NotchWings.capWidth(layout)
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                ArtworkView(state: state, size: NotchWings.artSize(layout))
                Spacer(minLength: 0)
            }
            .padding(.leading, NotchWings.edgePad)
            .frame(width: cap)

            wingText(bar.left, alignment: .center)
                .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                WingMeter(state: state, height: NotchWings.artSize(layout) * 0.7)
            }
            .padding(.trailing, NotchWings.edgePad)
            .frame(width: cap)
        }
        .padding(.horizontal, NotchLayout.flare)
        .frame(width: bar.totalWidth, height: layout.barHeight)
    }

    private var splitRow: some View {
        let gap = NotchWings.notchGap(layout)
        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                ArtworkView(state: state, size: NotchWings.artSize(layout))
                Spacer(minLength: NotchWings.innerGap)
                wingText(bar.left, alignment: .trailing)
            }
            .padding(.leading, NotchWings.edgePad)
            .padding(.trailing, gap)
            .frame(width: bar.wing)

            Color.clear.frame(width: layout.notchWidth)

            HStack(spacing: 0) {
                wingText(bar.right, alignment: .leading)
                Spacer(minLength: NotchWings.innerGap)
                WingMeter(state: state, height: NotchWings.artSize(layout) * 0.7)
            }
            .padding(.leading, gap)
            .padding(.trailing, NotchWings.edgePad)
            .frame(width: bar.wing)
        }
        .padding(.horizontal, NotchLayout.flare)
        .frame(height: layout.barHeight)
    }

    /// One wing's text. A new line rolls in: the old one lifts up and out
    /// while the new one rises from below, clipped to the bar.
    private func wingText(_ text: String, alignment: Alignment) -> some View {
        let travel = layout.barHeight * 0.5
        return ZStack(alignment: alignment) {
            Text(text)
                .font(AppFont.medium(layout.cpt(NotchWings.fontSize)))
                .foregroundStyle(Color.white.opacity(state.nowPlaying == nil ? 0.65 : 1.0))
                .lineLimit(1)
                .truncationMode(.tail)
                .id(text)
                .transition(Motion.reduced
                    ? AnyTransition.opacity
                    : AnyTransition.asymmetric(insertion: AnyTransition(LineRollIn(travel: travel)),
                                               removal: AnyTransition(LineRollOut(travel: travel))))
        }
        .frame(height: layout.barHeight)
        // Clip top and bottom only: the wing's width changes between lines,
        // and a full clip would cut the outgoing text off at the sides.
        .mask { Rectangle().padding(.horizontal, -layout.expandedWidth) }
        .animation(Motion.reduced ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.9),
                   value: text)
    }
}

/// The incoming line: rises from below on the roll's spring, and fades in a
/// beat behind it so it brightens as it settles rather than while it's low.
private struct LineRollIn: Transition {
    let travel: CGFloat

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .offset(y: phase.isIdentity ? 0 : travel)
            .animation(.easeOut(duration: 0.26).delay(0.06)) {
                $0.opacity(phase.isIdentity ? 1 : 0)
            }
    }
}

/// The outgoing line: lifts up on the roll's spring, and fades quickly so it's
/// gone before the new line arrives under it.
private struct LineRollOut: Transition {
    let travel: CGFloat

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .offset(y: phase.isIdentity ? 0 : -travel)
            .animation(.easeIn(duration: 0.16)) {
                $0.opacity(phase.isIdentity ? 1 : 0)
            }
    }
}

/// Four bars on the right wing. Real output levels while the audio engine is
/// running; otherwise a gentle synthetic motion that only says "playing", and
/// still bars when paused.
private struct WingMeter: View {
    @ObservedObject var state: PlaybackState
    @ObservedObject private var fx = AudioEffects.shared
    let height: CGFloat

    var body: some View {
        let playing = state.nowPlaying?.isPlaying ?? false
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !playing || Motion.reduced)) { context in
            let levels = barLevels(at: context.date.timeIntervalSinceReferenceDate, playing: playing)
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(Color.white.opacity(playing ? 0.85 : 0.4))
                        .frame(width: 2.5, height: max(3, height * levels[i]))
                }
            }
            .frame(width: NotchWings.meterWidth, height: height)
        }
        .accessibilityHidden(true)
    }

    private func barLevels(at t: Double, playing: Bool) -> [CGFloat] {
        guard playing else { return [0.25, 0.25, 0.25, 0.25] }
        if fx.engineRunning {
            // Last four peaks, newest on the right. sqrt lifts quiet passages
            // so the bars don't sit flat under normal listening levels.
            let recent = SharedAudio.levels.snapshot().suffix(4)
            return recent.map { CGFloat(min(1, max(0.15, sqrt($0)))) }
        }
        if Motion.reduced { return [0.5, 0.75, 0.6, 0.8] }
        let speeds = [5.1, 7.3, 6.2, 8.4]
        return speeds.enumerated().map { i, s in
            CGFloat(0.55 + 0.4 * sin(t * s + Double(i) * 1.7) * sin(t * 1.3 + Double(i)))
        }
    }
}

// MARK: - Open card
//
// Lyrics first: the lyric column takes the card, the current line is the
// largest thing on it, and the track, cover and controls sit in a footer
// strip under the scrubber. The strip beside the notch carries the time.

/// Every size on the open card, in one place. The card's height is computed
/// from these rather than left to layout, because the window's click area has
/// to know it too; the views use the same numbers, so the two always agree.
/// Each row gets a fixed height, and the lyrics sit at the top under the
/// notch with even gaps, so the card grows and shrinks with the current line
/// instead of floating it in leftover space.
@MainActor
enum CardMetrics {
    static let sidePadding: CGFloat = 16
    static let sideLineSize: CGFloat = 13
    static let lineMaxSize: CGFloat = 22
    static let lineMinSize: CGFloat = 17
    static let rowGap: CGFloat = 5
    static let topGap: CGFloat = 6
    static let lyricsToScrubber: CGFloat = 8
    static let scrubberHeight: CGFloat = 14
    static let scrubberToFooter: CGFloat = 4
    static let footerHeight: CGFloat = 28
    static let bottomPadding: CGFloat = 12

    /// Line box for text at `size`: Geist's ascent and descent (1.3 of the
    /// size), which already leaves air above the caps.
    static func rowHeight(_ size: CGFloat) -> CGFloat { ceil(size * 1.3) }

    /// Full horizontal inset, including the shape's top-corner flare.
    static func inset(_ layout: NotchLayout) -> CGFloat {
        layout.pt(sidePadding) + NotchLayout.flare
    }

    static func lyricWidth(_ layout: NotchLayout) -> CGFloat {
        layout.expandedWidth - inset(layout) * 2
    }

    static func sideRow(_ layout: NotchLayout) -> CGFloat { rowHeight(layout.pt(sideLineSize)) }

    /// Height of the current-line slot. While scrubbing it stays at what the
    /// slot needed when the scrub began, so the card doesn't resize under the
    /// cursor; otherwise it fits the line on screen.
    static func currentSlot(state: PlaybackState, layout: NotchLayout) -> CGFloat {
        if let anchor = state.scrubAnchorLine {
            return naturalSlot(for: anchor, layout: layout)
        }
        return naturalSlot(for: state.breakProgress == nil ? state.currentLine : nil, layout: layout)
    }

    /// The sung line's rows at the size it fits at, or one full-size row for
    /// the dots or a short gap.
    private static func naturalSlot(for line: String?, layout: NotchLayout) -> CGFloat {
        guard let line, !line.isEmpty else { return rowHeight(layout.pt(lineMaxSize)) }
        let fit = lineFit(line, layout: layout, maxLines: 2)
        return CGFloat(fit.lines.count) * rowHeight(fit.size)
    }

    static func lineFit(_ line: String, layout: NotchLayout, maxLines: Int) -> LyricLineFitter.Fit {
        LyricLineFitter.fit(line, fontName: AppFont.lyricLine, tracking: AppFont.lyricTracking,
                            maxSize: layout.pt(lineMaxSize), minSize: layout.pt(lineMinSize),
                            width: lyricWidth(layout), maxLines: maxLines)
    }

    /// How many rows the current line may use. Two normally; one when a
    /// scrub has locked the slot to a single row and the preview line would
    /// need two, in which case it shrinks (then trims) to fit the one.
    static func lineRows(for line: String, state: PlaybackState, layout: NotchLayout) -> Int {
        guard state.scrubAnchorLine != nil else { return 2 }
        let fit = lineFit(line, layout: layout, maxLines: 2)
        let needed = CGFloat(fit.lines.count) * rowHeight(fit.size)
        return needed <= currentSlot(state: state, layout: layout) ? 2 : 1
    }

    static func messageHeight(_ layout: NotchLayout) -> CGFloat {
        rowHeight(layout.pt(15)) + layout.pt(3) + rowHeight(layout.pt(11))
    }

    static func lyricsHeight(state: PlaybackState, layout: NotchLayout) -> CGFloat {
        guard state.lyricsStatus == .found else { return messageHeight(layout) }
        return sideRow(layout) * 3 + layout.pt(rowGap) * 3 + currentSlot(state: state, layout: layout)
    }

    /// The open card's full height, notch-height bar included.
    static func height(state: PlaybackState, layout: NotchLayout) -> CGFloat {
        guard state.isMusic else { return layout.barHeight + layout.expandedVideoH }
        return layout.barHeight
            + layout.pt(topGap)
            + lyricsHeight(state: state, layout: layout)
            + layout.pt(lyricsToScrubber)
            + layout.pt(scrubberHeight)
            + layout.pt(scrubberToFooter)
            + layout.pt(footerHeight)
            + layout.pt(bottomPadding)
    }
}

private struct ExpandedCard: View {
    @ObservedObject var state: PlaybackState
    let layout: NotchLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NotchBand(state: state, layout: layout)
                .frame(height: layout.barHeight)

            Group {
                if state.isMusic {
                    LyricStack(state: state, layout: layout)
                } else {
                    VideoHeading(state: state, layout: layout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.top, layout.pt(CardMetrics.topGap))

            // Exactly the gap for music, where the card is sized to fit;
            // takes up the slack under a video's title.
            Spacer(minLength: layout.pt(CardMetrics.lyricsToScrubber))

            Scrubber(state: state, layout: layout)
                .frame(height: layout.pt(CardMetrics.scrubberHeight))
            Spacer().frame(height: layout.pt(CardMetrics.scrubberToFooter))
            FooterRow(state: state, layout: layout)
                .frame(height: layout.pt(CardMetrics.footerHeight))
        }
    }
}

/// The strip either side of the camera on the open card. Only the time, on
/// the right, kept clear of the notch; the left side stays empty. While
/// scrubbing it shows where the scrub would land, brighter.
private struct NotchBand: View {
    @ObservedObject var state: PlaybackState
    let layout: NotchLayout

    var body: some View {
        let side = max(0, (CardMetrics.lyricWidth(layout) - layout.notchWidth) / 2 - 8)
        let scrubbing = state.scrubPosition != nil
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(state.nowPlaying == nil ? "" : "\(state.elapsedText) / \(state.durationText)")
                .font(.custom(AppFont.monoRegular, size: layout.pt(10)).monospacedDigit())
                .foregroundStyle(Color.white.opacity(scrubbing ? 0.95 : 0.45))
                .lineLimit(1)
                .frame(width: side, alignment: .trailing)
        }
    }
}

/// Drag anywhere on it to scrub: the lyrics and time follow the drag, and the
/// player seeks when it's released. A click jumps straight to that point.
/// The hit area is the full row; the visible track is a thin line that
/// thickens and grows a handle while hovered or dragged.
private struct Scrubber: View {
    @ObservedObject var state: PlaybackState
    let layout: NotchLayout
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let duration = state.nowPlaying?.duration ?? 0
            let shown = state.scrubPosition.map { duration > 0 ? $0 / duration : 0 } ?? state.progress
            let active = hovering || dragging
            let track: CGFloat = active ? 5 : 2
            let knob: CGFloat = 11
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16)).frame(height: track)
                Capsule()
                    .fill(LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(track, width * shown), height: track)
                Circle()
                    .fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: min(max(width * shown - knob / 2, 0), width - knob))
                    .opacity(active ? 1 : 0)
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0, width > 0 else { return }
                        dragging = true
                        state.previewScrub(to: min(max(value.location.x / width, 0), 1) * duration)
                    }
                    .onEnded { _ in
                        dragging = false
                        state.endScrub(commit: true)
                    }
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: active)
        }
        .disabled(state.nowPlaying == nil)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(state.elapsedText) of \(state.durationText)")
    }

    private var gradientColors: [Color] {
        let p = state.palette
        if p.count >= 2 { return [p[0], p[1]] }
        return [p.first ?? .white, p.first ?? .white]
    }
}

private struct LyricStack: View {
    @ObservedObject var state: PlaybackState
    let layout: NotchLayout

    var body: some View {
        switch state.lyricsStatus {
        case .found:
            lines
        case .notFound:
            message("No lyrics for this one", detail: "Couldn't find synced lyrics for this track.")
        case .loading, .none:
            message("Looking up lyrics…", detail: nil)
        }
    }

    private var lines: some View {
        // A line ending into an unmarked gap keeps its index, so the break
        // state is part of the slot's identity: the finished line moves up
        // and the dots come in with the same transition as a new line.
        let slot = SlotID(line: state.currentLineIndex ?? -1, inBreak: state.breakProgress != nil)
        let slotHeight = CardMetrics.currentSlot(state: state, layout: layout)
        return VStack(alignment: .leading, spacing: layout.pt(CardMetrics.rowGap)) {
            sideLine(state.previousLine, start: state.previousLineStart, opacity: 0.32)
            // One view whose text changes in place and slides in fresh on each
            // new line. Swapping in a new view per line (and fading out the
            // old one) could leave a stale line stuck under the current one.
            currentSlot
                .modifier(LineEntrance(trigger: slot))
                .frame(height: slotHeight, alignment: .leading)
            sideLine(state.nextLine, start: state.nextLineStart, opacity: 0.5)
            sideLine(state.lineAfterNext, start: state.lineAfterNextStart, opacity: 0.26)
        }
        .animation(Motion.reduced ? nil : .easeOut(duration: 0.25), value: slotHeight)
    }

    private struct SlotID: Hashable {
        let line: Int
        let inBreak: Bool
    }

    /// Colour of the current line and the break dots.
    private var ink: Color {
        ArtLooks.current.contains(.ink) ? ArtLooks.ink(state.palette) : .white
    }

    @ViewBuilder
    private var currentSlot: some View {
        let row = CardMetrics.rowHeight(layout.pt(CardMetrics.lineMaxSize))
        if let progress = state.breakProgress {
            BreakDots(progress: progress, size: layout.pt(9), ink: ink)
                .frame(height: row, alignment: .leading)
        } else if let line = state.currentLine, !line.isEmpty {
            SungLine(
                text: line,
                ink: ink,
                maxSize: layout.pt(CardMetrics.lineMaxSize),
                minSize: layout.pt(CardMetrics.lineMinSize),
                width: CardMetrics.lyricWidth(layout),
                maxLines: CardMetrics.lineRows(for: line, state: state, layout: layout)
            )
            // Clicking the line being sung starts it again.
            .seekable(to: state.currentLineStart, enabled: state.lyricsAreSynced, state: state)
        } else {
            // A gap too short for the dots: hold the row's height.
            Color.clear.frame(height: row)
        }
    }

    /// Previous and upcoming lines. Always laid out, even when empty, so the
    /// current line doesn't jump as neighbours come and go. Clicking one
    /// jumps the song to it.
    private func sideLine(_ text: String?, start: Double?, opacity: Double) -> some View {
        Text(text ?? " ")
            .font(AppFont.regular(layout.pt(CardMetrics.sideLineSize)))
            .foregroundStyle(Color.white.opacity(text == nil ? 0 : opacity))
            .lineLimit(1)
            .truncationMode(.tail)
            // Swap, don't crossfade, so old and new text never overlap.
            .contentTransition(.identity)
            .frame(height: CardMetrics.sideRow(layout), alignment: .leading)
            .seekable(to: text == nil ? nil : start, enabled: state.lyricsAreSynced, state: state)
    }

    private func message(_ title: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: layout.pt(3)) {
            Text(title)
                .font(AppFont.regular(layout.pt(15)))
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(height: CardMetrics.rowHeight(layout.pt(15)), alignment: .leading)
            Text(detail ?? " ")
                .font(AppFont.regular(layout.pt(11)))
                .foregroundStyle(Color.white.opacity(detail == nil ? 0 : 0.4))
                .frame(height: CardMetrics.rowHeight(layout.pt(11)), alignment: .leading)
        }
    }
}

/// Drops the content in from a few points below, fading up, whenever
/// `trigger` changes. The view itself stays the same, so there is never an
/// outgoing copy on screen.
private struct LineEntrance<Trigger: Hashable>: ViewModifier {
    let trigger: Trigger
    @State private var shown = true

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 6)
            .onChange(of: trigger) { _, _ in
                guard !Motion.reduced else { return }
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { shown = false }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.25)) { shown = true }
                }
            }
    }
}

/// Makes a lyric line jump the song to `start` when clicked, brightening a
/// little under the cursor so it reads as clickable. Unsynced lyrics have no
/// real times, so they stay inert.
private struct SeekableLine: ViewModifier {
    let start: Double?
    let enabled: Bool
    @ObservedObject var state: PlaybackState
    @State private var hovering = false

    func body(content: Content) -> some View {
        if let start, enabled {
            content
                .brightness(hovering ? 0.25 : 0)
                .contentShape(Rectangle())
                .onTapGesture { state.seek(toLineStartingAt: start) }
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        } else {
            content
        }
    }
}

private extension View {
    func seekable(to start: Double?, enabled: Bool, state: PlaybackState) -> some View {
        modifier(SeekableLine(start: start, enabled: enabled, state: state))
    }
}

/// The current line, wrapped to at most two lines and shown solid. Lyrics are
/// only timed per line, so it doesn't pretend to follow the words. Line breaks
/// are measured here rather than left to `Text`, so the card can size the slot
/// to the rows the line will actually take.
private struct SungLine: View {
    let text: String
    /// Colour of the line.
    var ink: Color = .white
    let maxSize: CGFloat
    let minSize: CGFloat
    let width: CGFloat
    /// Rows the line may wrap to; 1 while a scrub holds the slot at one row.
    var maxLines: Int = 2

    var body: some View {
        let fit = LyricLineFitter.fit(text, fontName: AppFont.lyricLine, tracking: AppFont.lyricTracking,
                                      maxSize: maxSize, minSize: minSize,
                                      width: width, maxLines: maxLines)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(fit.lines.enumerated()), id: \.offset) { _, line in
                styled(line, size: fit.size).foregroundStyle(ink)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    @ViewBuilder
    private func styled(_ line: LyricLineFitter.Line, size: CGFloat) -> some View {
        let base = Text(line.text)
            .font(.custom(AppFont.lyricLine, size: size))
            .tracking(size * AppFont.lyricTracking)
            .lineLimit(1)
        if line.truncated {
            base.truncationMode(.tail).frame(maxWidth: width, alignment: .leading)
        } else {
            // Measured to fit, so never let SwiftUI re-truncate it over a
            // sub-point rounding difference.
            base.fixedSize()
        }
    }
}

/// Three dots that fill one by one across an instrumental break, so the next
/// line arrives on the count rather than out of a blank row.
private struct BreakDots: View {
    let progress: Double
    let size: CGFloat
    /// Colour the dots fill with.
    var ink: Color = .white

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: Motion.reduced)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let breathe = Motion.reduced ? 1.0 : 1.0 + 0.08 * sin(t * 2 * .pi / 2.4)
            HStack(spacing: size * 0.8) {
                ForEach(0..<3, id: \.self) { i in
                    let lit = min(max(progress * 3 - Double(i), 0), 1)
                    Circle()
                        .fill(Color.white.opacity(0.22))
                        .overlay(Circle().fill(ink).scaleEffect(lit))
                        .frame(width: size, height: size)
                        .scaleEffect(breathe)
                }
            }
        }
        .animation(.linear(duration: 0.25), value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Instrumental break")
    }
}

/// Video and idle: no lyrics, so the title takes the space the lyrics would.
private struct VideoHeading: View {
    @ObservedObject var state: PlaybackState
    let layout: NotchLayout

    var body: some View {
        VStack(alignment: .leading, spacing: layout.pt(3)) {
            Text(state.nowPlaying?.title ?? "Nothing playing")
                .font(AppFont.regular(layout.pt(16)))
                .foregroundStyle(Color.white.opacity(state.nowPlaying == nil ? 0.65 : 1))
                .lineLimit(2)
            if state.nowPlaying == nil {
                Text("Play something and its lyrics show up here.")
                    .font(AppFont.regular(layout.pt(11)))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
    }
}

private struct FooterRow: View {
    @ObservedObject var state: PlaybackState
    let layout: NotchLayout

    var body: some View {
        HStack(spacing: layout.pt(10)) {
            if state.isMusic {
                ArtworkView(state: state, size: layout.pt(28))
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.nowPlaying?.title ?? "Nothing playing")
                        .font(AppFont.semiBold(layout.pt(12)))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(AppFont.regular(layout.pt(11)))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: layout.pt(8))
            if state.nowPlaying != nil {
                ControlsRow(state: state, layout: layout)
            }
        }
        .frame(height: layout.pt(28))
    }

    private var subtitle: String {
        guard let np = state.nowPlaying else { return "—" }
        return np.artist.isEmpty ? np.sourceName : np.artist
    }
}

private struct ArtworkView: View {
    @ObservedObject var state: PlaybackState
    let size: CGFloat

    var body: some View {
        Group {
            if let img = state.artwork {
                // `.fill` (centre-crop) keeps the artwork edge-to-edge inside
                // its circular clip. With `.fit` non-square artwork letterboxes
                // into black bars that show through the round clip and make
                // the radii look mismatched.
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
                    .background(Color.black.opacity(0.4))
            } else if state.nowPlaying == nil {
                // Disco-ball idle state.
                Text("🪩")
                    .font(.system(size: size * 0.72))
                    .frame(width: size, height: size)
            } else {
                ZStack {
                    Rectangle().fill(Color.white.opacity(0.08))
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.45, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(width: size, height: size)
            }
        }
        // Rounded-square album-art aesthetic — softer than a hard 4pt corner
        // but kept short of a full circle (size/2) which feels too "icon-y"
        // for music artwork.
        .clipShape(RoundedRectangle(cornerRadius: size <= 24 ? 6 : 8, style: .continuous))
        .shadow(color: .black.opacity(state.isHovering ? 0.4 : 0), radius: 5, x: 0, y: 2)
    }
}

// MARK: - Controls

private struct ControlsRow: View {
    @ObservedObject var state: PlaybackState
    let layout: NotchLayout

    var body: some View {
        let dia = layout.pt(26)
        HStack(spacing: layout.pt(6)) {
            if state.sourceSupportsTrackSkip {
                ControlButton(symbol: "backward.fill", size: layout.pt(10), diameter: dia) { state.previousTrack() }
            }
            ControlButton(symbol: (state.nowPlaying?.isPlaying ?? false) ? "pause.fill" : "play.fill",
                          size: layout.pt(12), diameter: dia) {
                state.togglePlayPause()
            }
            if state.sourceSupportsTrackSkip {
                ControlButton(symbol: "forward.fill", size: layout.pt(10), diameter: dia) { state.nextTrack() }
            }
        }
        .frame(height: dia)
    }
}

private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let diameter: CGFloat
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(hovering ? 0.14 : 0.06))
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovering ? 1.0 : 0.88))
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(ControlButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: hovering)
    }
}

/// Emil-Kowalski-style press feedback: tight spring on press-in, soft spring-back on release.
/// Hover lift is separate and only applies when not currently pressed.
private struct ControlButtonStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let scale: CGFloat = pressed ? 0.9 : (hovering ? 1.04 : 1.0)
        let response: Double = pressed ? 0.18 : 0.32
        let damping: Double  = pressed ? 0.7  : 0.78
        return configuration.label
            .scaleEffect(scale)
            .animation(.spring(response: response, dampingFraction: damping), value: pressed)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: hovering)
    }
}

