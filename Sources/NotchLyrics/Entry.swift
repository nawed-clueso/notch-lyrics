import AppKit

@main
@MainActor
struct NotchLyricsApp {
    static func main() {
        let app = NSApplication.shared
        // A regular app, not an accessory: it owns a real window, a Dock icon,
        // and a menu bar. The notch pill is one of its windows, not the whole
        // product.
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        MainMenuBuilder.install(target: delegate)
        app.run()
    }
}
