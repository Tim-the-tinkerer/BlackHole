import AppKit
import SwiftUI

@main
struct MainEntry {
    static func main() {
        let args = CommandLine.arguments

        if args.contains("--self-test") {
            if let err = SelfTest.run() {
                fputs("SELF-TEST FAILED: \(err)\n", stderr)
                exit(1)
            }
            print("SELF-TEST OK")
            print("Frames, paths, checksums, names, local addresses, and a file copy.")
            exit(0)
        }

        if args.contains("--help") || args.contains("-h") {
            print(helpText)
            exit(0)
        }

        if args.contains("--version") {
            print("\(AppInfo.name) \(AppInfo.version) (\(AppInfo.build))")
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    private static let helpText = """
    \(AppInfo.name) \(AppInfo.version) — drop files onto another Mac

    Usage:
      BlackHole                 Open the drop zone
      BlackHole --self-test     Check the copy path
      BlackHole --help
      BlackHole --version

    Open Black hole on two Macs on the same network. When the other
    computer's name appears, drop files or folders on the disk. They
    are copied into Downloads/Black hole on the other Mac. Originals
    stay where they are. Permission bits are copied. Dates, extended
    attributes, resource forks, and symlinks are not. Files are not encrypted.

    Closing the window leaves Black hole in the menu bar. It keeps
    listening. Show Black hole opens the disk again.
    """
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let model = HoleModel()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        installStatusItem()
        model.start()
        showMainWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitting = true
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Closing the disk hides it. The listener stays with the app, and the Dock icon leaves.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if quitting { return true }
        sender.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: ContentView(model: model))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = Theme.windowNS.cgColor

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppInfo.name
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.windowNS
        window.contentView = hosting
        window.minSize = NSSize(width: 320, height: 168)
        window.center()
        // A new name so an older saved frame does not open this window tall.
        window.setFrameAutosaveName("BlackHoleDisk.2")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "BlackHole.StatusItem"
        if let button = item.button {
            button.image = statusImage()
            button.image?.isTemplate = true
            button.toolTip = "Black hole"
            button.setAccessibilityTitle("Black hole")
            button.setAccessibilityHelp("Show received files, choose a folder, set a pairing code, or open the window.")
        }
        item.menu = buildStatusMenu()
        statusItem = item
    }

    private func statusImage() -> NSImage {
        if let symbol = NSImage(systemSymbolName: "smallcircle.filled.circle", accessibilityDescription: "Black hole") {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            let sized = symbol.withSymbolConfiguration(config) ?? symbol
            sized.isTemplate = true
            return sized
        }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1.4
            ring.stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 6.5, y: 6.5, width: 5, height: 5)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(command("Show Received Files", #selector(reveal(_:)), key: "r"))
        menu.addItem(command("Receive Folder…", #selector(chooseFolder(_:))))
        menu.addItem(command("Pairing Code…", #selector(pairing(_:))))
        menu.addItem(.separator())
        menu.addItem(command("Close", #selector(closeWindow(_:)), key: "w"))
        menu.addItem(.separator())
        menu.addItem(command("Show Black hole", #selector(showWindow(_:))))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Black hole", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    private func command(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(closeWindow(_:)) {
            return window?.isVisible == true
        }
        return true
    }

    @objc private func reveal(_ sender: Any?) {
        model.reveal()
    }

    @objc private func chooseFolder(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        model.chooseFolder()
    }

    @objc private func pairing(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        model.promptPairing()
    }

    @objc private func closeWindow(_ sender: Any?) {
        window?.performClose(sender)
    }

    @objc private func showWindow(_ sender: Any?) {
        showMainWindow()
    }

    @objc private func showAbout(_ sender: Any?) {
        let folder = Identity.receiveFolder().path
        let code = Identity.pairingCode()
        let codeLine = code.isEmpty ? "Pairing code is blank, so every Black hole on this network can link." : "A pairing code is set. The other Mac needs the same code."
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: AppInfo.name,
            .version: AppInfo.version,
            .applicationVersion: "Version \(AppInfo.version) (\(AppInfo.build))",
            .credits: NSAttributedString(
                string: """
                Drop files on the disk. They are copied to every other Mac \
                on this network that has Black hole open.

                Received files land in:
                \(folder)

                Originals are left where they are. Nothing is encrypted, \
                so use it on a network you trust.

                \(codeLine)
                """,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ),
        ]
        if let icon = NSApp.applicationIconImage {
            options[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let about = appMenu.addItem(withTitle: "About Black hole", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Black hole", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Black hole", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(command("Show Received Files", #selector(reveal(_:)), key: "r"))
        fileMenu.addItem(command("Receive Folder…", #selector(chooseFolder(_:))))
        fileMenu.addItem(command("Pairing Code…", #selector(pairing(_:))))
        fileMenu.addItem(.separator())
        fileMenu.addItem(command("Close", #selector(closeWindow(_:)), key: "w"))

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(command("Show Black hole", #selector(showWindow(_:)), key: "0"))
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
