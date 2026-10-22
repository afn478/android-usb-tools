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

    // MARK: Helper registration

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
                    }
                    self.refresh()
                }
            }
        }
    }

    private func askForApproval() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow the Tether helper"
        alert.informativeText = """
            Tether needs a background helper with administrator rights to drive the phone's \
            USB connection. Turn on “Tether” under “Allow in the Background” in System Settings; \
            macOS will ask for your password or Touch ID.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    @objc private func approveHelper() {
        registerDaemon()
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func uninstallHelper() {
        daemon.unregister { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    NSAlert(error: error).runModal()
                }
                self?.refresh()
            }
        }
    }

    @objc private func reinstallHelper() {
        promptedForApproval = false
        registerDaemon()
        refresh()
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
        case "connecting": return .connecting(status["Device"] as? String ?? "phone")
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
            info("Connected to \(s["Device"] as? String ?? "phone")")
            info("\(s["Address"] as? String ?? "?") via \(s["Router"] as? String ?? "?") on \(s["Interface"] as? String ?? "?")")
        case .connecting(let device):
            info("Connecting to \(device)…")
        case .waiting:
            info("Waiting for a phone")
            info("Plug in and turn on USB tethering")
        case .needsApproval:
            info("Helper needs approval")
            _ = action("Approve in System Settings…", #selector(approveHelper))
        case .notRunning:
            info("Helper isn't running")
            _ = action("Install Helper", #selector(reinstallHelper))
        }

        menu.addItem(.separator())
        let login = action("Open at Login", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        _ = action("Show Log", #selector(openLog))
        if daemon.status == .enabled {
            _ = action("Uninstall Helper", #selector(uninstallHelper))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tether", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}
