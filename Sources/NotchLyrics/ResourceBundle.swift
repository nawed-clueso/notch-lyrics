import Foundation

extension Bundle {
    /// The target's bundled resources (fonts, the visualizer page).
    ///
    /// Use this, never `Bundle.module`. SwiftPM's accessor only looks at the
    /// app root and at the absolute `.build` path of the Mac that built it,
    /// and fatal-errors otherwise. A packaged app keeps the bundle in
    /// Contents/Resources (nothing else may sit at the root of a signed app),
    /// so `Bundle.module` works on the build machine and crashes everywhere
    /// else. `scripts/build-dmg.sh` refuses to package if it's used.
    static let appResources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("NotchLyrics_NotchLyrics.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        // `swift run` and other unpackaged builds.
        return .module
    }()
}
