import AppKit
import Metal

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window:   NSWindow!
    private var gameView: GameView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this Mac")
        }

        let frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        window = NSWindow(
            contentRect: frame,
            styleMask:   [.titled, .closable, .miniaturizable],
            backing:     .buffered,
            defer:       false
        )
        window.backgroundColor = .black
        window.center()

        gameView = GameView(frame: frame, device: device)
        window.contentView = gameView

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(gameView)

        buildMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let bar     = NSMenu()
        let appItem = NSMenuItem()
        bar.addItem(appItem)

        let appMenu = NSMenu(title: "Lunar Lander")
        appMenu.addItem(
            NSMenuItem(title: "Quit Lunar Lander",
                       action: #selector(NSApplication.terminate(_:)),
                       keyEquivalent: "q")
        )
        appItem.submenu = appMenu
        NSApp.mainMenu  = bar
    }
}
