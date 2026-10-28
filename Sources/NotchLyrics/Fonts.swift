import AppKit
import SwiftUI
import CoreText

/// Bundled typefaces, registered with CoreText at launch so
/// `Font.custom(_:size:)` can find them by PostScript name.
///
/// Instrument Serif for titles (formal, high contrast, holds up large),
/// Work Sans for the app window's UI and prose (humanist, still legible at
/// 11pt), Geist for everything in the notch pill, and Geist Mono for values
/// and commands. The pill and its timestamps share one family, so the notch
/// reads as a single system.
enum AppFont {
    static let titleSerif = "InstrumentSerif-Regular"
    static let bodyRegular = "WorkSans-Regular"
    static let bodySemibold = "WorkSans-SemiBold"
    static let pillRegular = "Geist-Regular"
    static let pillMedium = "Geist-Medium"
    static let pillSemibold = "Geist-SemiBold"
    static let monoRegular = "GeistMono-Regular"

    /// The line being sung. Semibold and tracked in a little, so it reads as
    /// a lyric rather than body copy and stands apart from its neighbours.
    static let lyricLine = pillSemibold
    /// Letter spacing for `lyricLine`, as a fraction of the point size.
    static let lyricTracking: CGFloat = -0.025

    private static let bundled = [
        ("InstrumentSerif-Regular", "ttf"),
        ("WorkSans-Regular", "ttf"),
        ("WorkSans-SemiBold", "ttf"),
        ("Geist-Regular", "otf"),
        ("Geist-Medium", "otf"),
        ("Geist-SemiBold", "otf"),
        ("GeistMono-Regular", "otf"),
        ("GeistMono-Medium", "otf"),
        ("GeistMono-SemiBold", "otf"),
    ]

    /// Idempotent — safe to call repeatedly.
    static func registerAll() {
        guard !registered else { return }
        registered = true

        for (name, ext) in bundled {
            guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
                NSLog("⚠️ Missing font resource: \(name).\(ext)")
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                if let err = error?.takeRetainedValue() {
                    NSLog("⚠️ Failed to register \(name): \(err)")
                }
            }
        }

        // Registration is silent on failure at the call site, so verify once:
        // a missing family falls back to the system font and the whole app
        // quietly looks wrong.
        for name in [titleSerif, bodyRegular, bodySemibold, pillRegular, pillMedium, pillSemibold, monoRegular] where NSFont(name: name, size: 12) == nil {
            NSLog("⚠️ Font unavailable after registration: \(name)")
        }
    }
    nonisolated(unsafe) private static var registered = false

    // MARK: - Size helpers
    //
    // The notch pill sizes type against its own geometry rather than the app's
    // type scale, so it asks for a family at an explicit size. Geist stays
    // crisp small and light-on-dark, which is all the pill ever does.

    static func regular(_ size: CGFloat) -> Font  { .custom(pillRegular, size: size) }
    static func medium(_ size: CGFloat) -> Font   { .custom(pillMedium, size: size) }
    static func semiBold(_ size: CGFloat) -> Font { .custom(pillSemibold, size: size) }
}
