import AppKit

/// Builds the app's menu bar in code. There is no nib in a SwiftPM executable,
/// and a regular (non-accessory) app without a menu bar has no Quit, no
/// Copy/Paste in text fields, and no Enter Full Screen — so this is required,
/// not decoration. Every item uses a standard responder selector unless it
/// needs app-specific behaviour.
@MainActor
enum MainMenuBuilder {

    static func install(target: AnyObject) {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Notch Lyrics"

        let root = NSMenu()
        root.addItem(appMenu(appName: appName))
        root.addItem(editMenu())
        root.addItem(viewMenu(target: target))
        let window = windowMenu(target: target)
        root.addItem(window)
        NSApp.mainMenu = root
        // Lets macOS add the standard window list and manage checkmarks.
        NSApp.windowsMenu = window.submenu
    }

    // MARK: App

    private static func appMenu(appName: String) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()

        menu.addItem(withTitle: "About \(appName)",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        let hide = menu.addItem(withTitle: "Hide \(appName)",
                                action: #selector(NSApplication.hide(_:)),
                                keyEquivalent: "h")
        hide.keyEquivalentModifierMask = [.command]

        let hideOthers = menu.addItem(withTitle: "Hide Others",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]

        menu.addItem(withTitle: "Show All",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(appName)",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    // MARK: Edit
    //
    // Needed for the device pickers and the selectable shell commands: without
    // an Edit menu, Command-C does nothing anywhere in the app.

    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Edit")

        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        item.submenu = menu
        return item
    }

    // MARK: View

    private static func viewMenu(target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "View")

        let setup = menu.addItem(withTitle: "Setup",
                                 action: #selector(AppDelegate.showSetupPane),
                                 keyEquivalent: "1")
        setup.target = target
        let audio = menu.addItem(withTitle: "Audio",
                                 action: #selector(AppDelegate.showAudioPane),
                                 keyEquivalent: "2")
        audio.target = target

        menu.addItem(.separator())
        let full = menu.addItem(withTitle: "Enter Full Screen",
                                action: #selector(NSWindow.toggleFullScreen(_:)),
                                keyEquivalent: "f")
        // macOS retitles this to "Exit Full Screen" itself once in full screen.
        full.keyEquivalentModifierMask = [.command, .control]

        item.submenu = menu
        return item
    }

    // MARK: Window

    private static func windowMenu(target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Window")

        menu.addItem(withTitle: "Minimize",
                     action: #selector(NSWindow.performMiniaturize(_:)),
                     keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom",
                     action: #selector(NSWindow.performZoom(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        // The main window can be closed while the notch pill keeps running, so
        // there has to be a way back to it that isn't the Dock icon.
        let main = menu.addItem(withTitle: "Notch Lyrics",
                                action: #selector(AppDelegate.showMainWindow),
                                keyEquivalent: "0")
        main.target = target

        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front",
                     action: #selector(NSApplication.arrangeInFront(_:)),
                     keyEquivalent: "")

        item.submenu = menu
        return item
    }
}
