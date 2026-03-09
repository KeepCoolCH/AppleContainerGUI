import SwiftUI
import AppKit

@main
struct AppleContainerGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var windowObserver: Any?
    private var openWindowWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            if let window = notification.object as? NSWindow {
                window.isRestorable = false
            }
        }
        Task { _ = await ContainerCLI.shared.run(["system", "start"]) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow()
        return true
    }

    private func setupStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "AppleContainerGUI")
        }

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open AppleContainerGUI", action: #selector(openWindow), keyEquivalent: "o")
        openItem.target = self
        openItem.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
        let startItem = NSMenuItem(title: "Start Container System", action: #selector(startSystem), keyEquivalent: "s")
        startItem.target = self
        startItem.image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: nil)
        let stopItem = NSMenuItem(title: "Stop Container System", action: #selector(stopSystem), keyEquivalent: "t")
        stopItem.target = self
        stopItem.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)

        menu.addItem(openItem)
        menu.addItem(.separator())
        menu.addItem(startItem)
        menu.addItem(stopItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        statusItem.menu = menu
        self.statusItem = statusItem
    }

    @objc private func openWindow() {
        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.unhide(nil)

        openWindowWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
            mainWindow = window
            window.title = "AppleContainerGUI"
            bringToFront(window)
            return
        }
        if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
            mainWindow = window
            window.title = "AppleContainerGUI"
            window.makeKeyAndOrderFront(nil)
            bringToFront(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: ContentView())
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = "AppleContainerGUI"
        window.center()
            mainWindow = window
            window.makeKeyAndOrderFront(nil)
            bringToFront(window)
        }

        openWindowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func bringToFront(_ window: NSWindow) {
        let app = NSRunningApplication.current
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            guard window.isVisible else { return }
            app.activate(options: [.activateAllWindows])
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            app.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard window.isVisible else { return }
            app.activate(options: [.activateAllWindows])
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self else { return }
            guard window.isVisible else { return }
            guard window.isKeyWindow == false else { return }
            if let existing = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
                mainWindow = existing
                existing.makeKeyAndOrderFront(nil)
                existing.orderFrontRegardless()
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            let fallback = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1320, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            fallback.contentView = NSHostingView(rootView: ContentView())
            fallback.delegate = self
            fallback.isReleasedWhenClosed = false
            fallback.center()
            self.mainWindow = fallback
            app.activate(options: [.activateAllWindows])
            fallback.makeKeyAndOrderFront(nil)
            fallback.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        openWindowWorkItem?.cancel()
        openWindowWorkItem = nil
    }

    @objc private func startSystem() {
        Task { _ = await ContainerCLI.shared.run(["system", "start"]) }
    }

    @objc private func stopSystem() {
        Task { _ = await ContainerCLI.shared.run(["system", "stop"]) }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
