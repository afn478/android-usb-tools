// Tether: menu bar front end for the rndis-tether helper.
//
// Registers the bundled helper as a launchd daemon via SMAppService and shows
// the state the helper publishes in the dynamic store.

import AppKit
import ServiceManagement
import SystemConfiguration

private let statusKey = "State:/rndis-tether/Status" as CFString
private let daemonPlist = "io.github.afn478.rndis-tether.plist"
private let logPath = "/var/log/rndis-tether.log"
private let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let daemon = SMAppService.daemon(plistName: daemonPlist)
    private var statusItem: NSStatusItem!
    private var store: SCDynamicStore?
    private var approvalTimer: Timer?
    private var promptedForApproval = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The background permission is tied to where the app lives, so make
        // sure that's the Applications folder before asking for it.
        if moveToApplicationsIfNeeded() { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        watchStatus()
        if !UserDefaults.standard.bool(forKey: "didSetUpLoginItem") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didSetUpLoginItem")
        }
        registerDaemon()
        refresh()
    }

    // MARK: Installation

    /// Returns true if the app is relaunching from /Applications or quitting.
    private func moveToApplicationsIfNeeded() -> Bool {
        let bundleURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        if bundleURL.deletingLastPathComponent().path == applicationsURL.path { return false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Tether to your Applications folder?"
        alert.informativeText = "Tether needs to be in your Applications folder to work."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return true
        }

        let destination = applicationsURL.appendingPathComponent(bundleURL.lastPathComponent)
        do {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
            where app != .current {
                app.terminate()
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            try FileManager.default.copyItem(at: bundleURL, to: destination)
        } catch {
            let failure = NSAlert()
            failure.messageText = "Tether couldn’t be moved"
            failure.informativeText = "Drag Tether into your Applications folder yourself, then open it from there."
            failure.runModal()
            NSApp.terminate(nil)
            return true
        }

        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    private func registerDaemon() {
        if daemon.status == .notRegistered || daemon.status == .notFound {
            do {
                try daemon.register()
            } catch {
                // Registering an unapproved daemon reports an error but still
                // leaves it waiting for approval in System Settings.
                NSLog("Tether: register helper: \(error)")
            }
        }
        if daemon.status == .requiresApproval {
            if !promptedForApproval {
                promptedForApproval = true
                askForApproval()
            }
            // There's no notification for approval, so poll until it happens.
            if approvalTimer == nil {
                approvalTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    if self.daemon.status != .requiresApproval {
                        self.approvalTimer?.invalidate()
                        self.approvalTimer = nil
                        if self.daemon.status == .enabled { self.announceReady() }
                    }
                    self.refresh()
                }
            }
        }
    }

    private func askForApproval() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Finish setting up Tether"
        alert.informativeText = """
            To use your phone’s internet over a USB cable, Tether needs to run in the background.

            In the window that opens, switch on Tether, then confirm with Touch ID or your password. \
            You only need to do this once.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func announceReady() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Tether is ready"
        alert.informativeText = """
            Connect your phone with a USB cable and turn on USB tethering in its settings. \
            Your Mac will start using the phone’s internet automatically.

            Look for Tether’s icon in the menu bar to see when you’re connected.
            """
        alert.runModal()
    }

    @objc private func finishSetup() {
        registerDaemon()
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func restartSetup() {
        promptedForApproval = false
        registerDaemon()
        refresh()
    }

    @objc private func removeTether() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove Tether from this Mac?"
        alert.informativeText = "Your Mac will no longer be able to use your phone’s internet over USB."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        try? SMAppService.mainApp.unregister()
        daemon.unregister { _ in
            DispatchQueue.main.async {
                UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
                NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            }
        }
    }

    @objc private func toggleLoginItem() {
        let app = SMAppService.mainApp
        do {
            if app.status == .enabled { try app.unregister() } else { try app.register() }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: logPath)],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Status

    private func watchStatus() {
        var ctx = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "Tether" as CFString, { _, _, info in
            let me = Unmanaged<AppDelegate>.fromOpaque(info!).takeUnretainedValue()
            // The helper replaces the key by removing and re-adding it; let the
            // pair settle before redrawing so the icon doesn't flicker.
            NSObject.cancelPreviousPerformRequests(withTarget: me, selector: #selector(AppDelegate.refresh), object: nil)
            me.perform(#selector(AppDelegate.refresh), with: nil, afterDelay: 0.2)
        }, &ctx)
        guard let store else { return }
        SCDynamicStoreSetNotificationKeys(store, [statusKey] as CFArray, nil)
        let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private enum State {
        case needsApproval, notRunning, waiting, connecting(String), connected([String: Any])
    }

    private var state: State {
        switch daemon.status {
        case .requiresApproval: return .needsApproval
        case .enabled: break
        default: return .notRunning
        }
        guard let store, let status = SCDynamicStoreCopyValue(store, statusKey) as? [String: Any] else {
            return .notRunning
        }
        switch status["State"] as? String {
        case "connected": return .connected(status)
        case "connecting": return .connecting(status["Device"] as? String ?? "your phone")
        default: return .waiting
        }
    }

    @objc func refresh() {
        guard let button = statusItem.button else { return }
        let symbol: String
        var dimmed = false
        switch state {
        case .connected:
            symbol = "personalhotspot"
        case .connecting, .waiting:
            symbol = "personalhotspot"
            dimmed = true
        case .needsApproval, .notRunning:
            symbol = "exclamationmark.triangle"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Tether")
        button.image?.isTemplate = true
        button.appearsDisabled = dimmed
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        func action(_ title: String, _ selector: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return item
        }

        switch state {
        case .connected(let s):
            info("Connected to \(s["Device"] as? String ?? "your phone")")
            info("Your Mac is using the phone’s internet")
            menu.addItem(.separator())
            info("IP Address: \(s["Address"] as? String ?? "–")")
            info("Router: \(s["Router"] as? String ?? "–")")
            info("Interface: \(s["Interface"] as? String ?? "–")")
        case .connecting(let device):
            info("Connecting to \(device)…")
        case .waiting:
            info("No phone connected")
            info("Plug in your phone and turn on USB tethering")
        case .needsApproval:
            info("Setup isn’t finished")
            _ = action("Finish Setup…", #selector(finishSetup))
        case .notRunning:
            info("Tether is turned off")
            _ = action("Turn On Tether…", #selector(restartSetup))
        }

        menu.addItem(.separator())
        let login = action("Open at Login", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        _ = action("Show Log", #selector(openLog))
        _ = action("Remove Tether…", #selector(removeTether))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tether", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}
