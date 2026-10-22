import AppKit
import SwiftUI
import CoreText

/// Bundled typefaces, registered with CoreText at launch so
/// `Font.custom(_:size:)` can find them by PostScript name.
///
/// Three roles, each a real family rather than a weight of the same one:
/// Instrument Serif for titles (formal, high contrast, holds up large),
/// Work Sans for everything read as UI or prose (humanist, still legible at
/// 11pt), Geist Mono for values and commands.
enum AppFont {
    static let titleSerif = "InstrumentSerif-Regular"
    static let bodyRegular = "WorkSans-Regular"
    static let bodySemibold = "WorkSans-SemiBold"
    static let monoRegular = "GeistMono-Regular"

    private static let bundled = [
        ("InstrumentSerif-Regular", "ttf"),
        ("WorkSans-Regular", "ttf"),
        ("WorkSans-SemiBold", "ttf"),
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
        for name in [titleSerif, bodyRegular, bodySemibold, monoRegular] where NSFont(name: name, size: 12) == nil {
            NSLog("⚠️ Font unavailable after registration: \(name)")
        }
    }
    nonisolated(unsafe) private static var registered = false

    // MARK: - Size helpers
    //
    // The notch pill sizes type against its own geometry rather than the app's
    // type scale, so it asks for a family at an explicit size. Work Sans reads
    // well small and light-on-dark, which is all the pill ever does.

    static func regular(_ size: CGFloat) -> Font  { .custom(bodyRegular, size: size) }
    static func medium(_ size: CGFloat) -> Font   { .custom(bodyRegular, size: size) }
    static func semiBold(_ size: CGFloat) -> Font { .custom(bodySemibold, size: size) }
}
