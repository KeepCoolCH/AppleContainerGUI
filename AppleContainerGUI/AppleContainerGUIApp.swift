import SwiftUI
import AppKit

@main
struct AppleContainerGUIApp: App {
    static var displayTitle: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else { return "AppleContainerGUI" }
        return "AppleContainerGUI V.\(version)"
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private struct MenuContainer: Decodable {
        let Id: String
        let Names: [String]
        let State: String
        let Labels: [String: String]?
        var name: String { Names.first.map { String($0.drop(while: { $0 == "/" })) } ?? Id }
    }
    private var menuContainers: [MenuContainer] = []
    private var menuTimer: Timer?
    private var menuRefreshing = false
    private var menuTracking = false
    private var menuError: String?
    private var containerActionInFlight = false
    private var menuRevision = 0
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
                window.title = AppleContainerGUIApp.displayTitle
            }
        }
        Task {
            guard ManagedRuntime.shared.installedRoot != nil else { return }
            _ = await ContainerCLI.shared.run(["system", "start"])
            await DockerSocketService.shared.startup()
            if FileManager.default.fileExists(atPath: ManagedRuntime.shared.storage.appendingPathComponent("runtime-resume.json").path) {
                await DockerSocketService.shared.start()
                for _ in 0..<600 {
                    if !DockerSocketService.shared.isBusy { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard DockerSocketService.shared.isRunning else { return }
                do {
                    try await ManagedRuntime.shared.restoreContainers { _ in }
                } catch {
                    DockerSocketService.shared.lastError = error.localizedDescription
                }
            }
        }
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
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        self.statusItem = statusItem
        rebuildMenu()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshMenuContainers() }
        }
        menuTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        Task { await refreshMenuContainers() }
    }

    private func rebuildMenu() {
        guard !menuTracking, let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        @discardableResult
        func add(_ title: String, action: Selector? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = action != nil
            menu.addItem(item)
            return item
        }
        add("Open AppleContainerGUI", action: #selector(openWindow)).keyEquivalent = "o"
        if let menuError { add(menuError).toolTip = menuError }
        for running in [true, false] {
            menu.addItem(.separator())
            add(running ? "Running Containers" : "Stopped Containers")
            let containers = menuContainers.filter { ($0.State == "running") == running }
            if containers.isEmpty { add(running ? "No running containers" : "No stopped containers") }
            for container in containers {
                let row = add(container.name)
                row.isEnabled = true
                row.image = NSImage(systemSymbolName: running ? "play.circle.fill" : "stop.circle", accessibilityDescription: nil)
                row.toolTip = container.State
                let submenu = NSMenu(title: container.name)
                submenu.autoenablesItems = false
                for (title, command, enabled) in [("Start", "start", !running), ("Stop", "stop", running), ("Restart", "restart", running)] {
                    let item = NSMenuItem(title: title, action: #selector(containerAction(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = [container.Id, command]
                    item.isEnabled = enabled && !containerActionInFlight && menuError == nil
                    submenu.addItem(item)
                }
                row.submenu = submenu
            }
        }
        menu.addItem(.separator())
        add("Quit", action: #selector(quitApp)).keyEquivalent = "q"
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        menuTracking = true
        Task { await refreshMenuContainers() }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuTracking = false
    }

    private func refreshMenuContainers() async {
        guard !menuRefreshing else { return }
        menuRefreshing = true
        let revision = menuRevision
        defer { menuRefreshing = false }
        let service = DockerSocketService.shared
        guard service.isRunning, !service.socketPath.isEmpty else {
            menuContainers = []
            menuError = "Docker API is not running"
            rebuildMenu()
            return
        }
        do {
            let response = try await DockerAPIClient(socketPath: service.socketPath).request(path: "/containers/json?all=true")
            guard revision == menuRevision else { return }
            menuContainers = try response.decode([MenuContainer].self)
                .filter { $0.Labels?["socktainer.role"] != "dns" }
                .sorted { ($0.name, $0.Id) < ($1.name, $1.Id) }
            menuError = nil
        } catch {
            guard revision == menuRevision else { return }
            menuError = "Container list unavailable"
        }
        rebuildMenu()
    }

    @objc private func containerAction(_ sender: NSMenuItem) {
        guard !containerActionInFlight,
              let selection = sender.representedObject as? [String], selection.count == 2,
              let container = menuContainers.first(where: { $0.Id == selection[0] }),
              ["start", "stop", "restart"].contains(selection[1]),
              let id = selection[0].addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return }
        containerActionInFlight = true
        menuRevision += 1
        Task {
            defer { containerActionInFlight = false; rebuildMenu() }
            do {
                let service = DockerSocketService.shared
                guard service.isRunning else {
                    throw DockerAPIError(message: "Docker API is not running")
                }
                let result = await service.runDocker([selection[1], container.name], timeout: 90)
                guard result.code == 0 else {
                    throw DockerAPIError(message: result.error.isEmpty ? "Container action failed (exit code \(result.code))" : result.error)
                }
                let client = DockerAPIClient(socketPath: service.socketPath)
                let expectedRunning = selection[1] != "stop"
                let deadline = ContinuousClock.now + .seconds(45)
                while true {
                    let response = try await client.request(path: "/containers/" + id + "/json")
                    let object = try response.decode([String: JSONValue].self)
                    if case .object(let state) = object["State"],
                       case .bool(let running) = state["Running"], running == expectedRunning {
                        break
                    }
                    guard ContinuousClock.now < deadline else {
                        throw DockerAPIError(message: "The container has not reached the requested state. Check its status and runtime log.")
                    }
                    try await Task.sleep(for: .milliseconds(300))
                }
                menuRevision += 1
            } catch {
                let alert = NSAlert()
                alert.messageText = "Container action failed"
                alert.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
            await refreshMenuContainers()
        }
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
            window.title = AppleContainerGUIApp.displayTitle
            bringToFront(window)
            return
        }
        if let window = NSApp.windows.first(where: { $0.canBecomeKey }) {
            mainWindow = window
            window.title = AppleContainerGUIApp.displayTitle
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
        window.title = AppleContainerGUIApp.displayTitle
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
            fallback.title = AppleContainerGUIApp.displayTitle
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await DockerSocketService.shared.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        DockerSocketService.shared.terminateForAppExit()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
