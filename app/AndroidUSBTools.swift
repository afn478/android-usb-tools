// Android USB Tools: menu bar app for Android phones connected over USB.
//
// Registers the bundled tethering helper as a launchd daemon via SMAppService
// and shows the state the helper publishes in the dynamic store.

import AppKit
import ServiceManagement
import SystemConfiguration

private let appName = "Android USB Tools"
private let statusKey = "State:/rndis-tether/Status" as CFString
private let tetheringPlist = "io.github.afn478.AndroidUSBTools.tethering.plist"
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

    private let tethering = SMAppService.daemon(plistName: tetheringPlist)
    private var statusItem: NSStatusItem!
    private var store: SCDynamicStore?
    private var approvalTimer: Timer?
    private var promptedForApproval = false
    private lazy var files = FileAccess { [weak self] in self?.refresh() }
    private lazy var phones = PhoneWatcher { [weak self] in self?.refresh() }

    /// The background permission is tied to where the app lives, so it's only
    /// requested once the app has been dragged into /Applications.
    private let isInApplications =
        Bundle.main.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent().path == applicationsURL.path

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        watchStatus()
        files.start()
        phones.start()
        guard isInApplications else {
            refresh()
            return
        }
        if !UserDefaults.standard.bool(forKey: "didSetUpLoginItem") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "didSetUpLoginItem")
        }
        registerHelper()
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        files.stop()
    }

    // MARK: Installation

    private func registerHelper() {
        if tethering.status == .notRegistered || tethering.status == .notFound {
            do {
                try tethering.register()
            } catch {
                // Registering an unapproved daemon reports an error but still
                // leaves it waiting for approval in System Settings.
                NSLog("\(appName): register helper: \(error)")
            }
        }
        if tethering.status == .requiresApproval {
            if !promptedForApproval {
                promptedForApproval = true
                askForApproval()
            }
            // There's no notification for approval, so poll until it happens.
            if approvalTimer == nil {
                approvalTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    if self.tethering.status != .requiresApproval {
                        self.approvalTimer?.invalidate()
                        self.approvalTimer = nil
                        if self.tethering.status == .enabled { self.announceReady() }
                    }
                    self.refresh()
                }
            }
        }
    }

    private func askForApproval() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Finish setting up \(appName)"
        alert.informativeText = """
            To use your phone’s internet over a USB cable, \(appName) needs to run in the background.

            In the window that opens, switch on \(appName), then confirm with Touch ID or your password. \
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
        alert.messageText = "\(appName) is ready"
        alert.informativeText = """
            Connect your phone with a USB cable and turn on USB tethering in its settings. \
            Your Mac will start using the phone’s internet automatically.

            The cable icon in the menu bar shows when you’re connected.
            """
        alert.runModal()
    }

    @objc private func finishSetup() {
        registerHelper()
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func restartSetup() {
        promptedForApproval = false
        registerHelper()
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

    // MARK: Files

    @objc private func openVolume() { files.openVolume() }
    @objc private func ejectVolume() { files.eject() }
    @objc private func mountVolume() { files.mount() }
    @objc private func toggleOpenInFinder() { files.openInFinder.toggle() }

    @objc private func getMacFUSE() {
        NSWorkspace.shared.open(URL(string: "https://macfuse.github.io")!)
    }

    @objc private func showMountLog() {
        NSWorkspace.shared.open(
            [FileAccess.logURL],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
            configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func enableMacFUSE() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Turn on macFUSE"
        alert.informativeText = """
            \(appName) shows your phone in Finder through macFUSE, which needs to be switched on once.

            In the window that opens, click ⓘ next to File System Extensions, choose “By Category” at the top, \
            and switch on macFUSE and macFUSE (local). (The switches in the “By Application” view don’t stay on.)

            Then unplug your phone and plug it in again.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        }
    }

    // MARK: USB mode help

    @objc private func showModeHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Which USB mode do I need?"
        var now: String
        if let phone = phones.phones.first {
            switch phone.mode {
            case .fileTransfer:
                now = "\(phone.name) is in File transfer mode, so its files are in Finder."
            case .tethering:
                now = "\(phone.name) is in USB tethering mode, so your Mac can use its internet."
            case .noData:
                now = "\(phone.name) is only charging. Choose a mode on the phone to use it with your Mac."
            case .photos:
                now = "\(phone.name) is in PTP mode, which only shares photos. Choose File transfer instead."
            case .midi:
                now = "\(phone.name) is in MIDI mode, which \(appName) doesn’t use."
            }
        } else {
            now = "No Android phone is connected. Plug it in with a USB data cable (some cables only charge)."
        }
        alert.informativeText = """
            \(now)

            File transfer: browse, copy and edit the phone’s files in Finder.
            USB tethering: use the phone’s internet on this Mac.

            To switch, unlock the phone, pull down from the top of the screen and tap the USB notification \
            (it may say “Charging this device via USB”). File transfer is in that list. USB tethering is either \
            in the same list or under Settings → Network & internet → Hotspot & tethering.

            Most phones do one at a time. \(appName) notices the switch and changes over by itself.
            """
        alert.addButton(withTitle: "OK")
        if case .mounted = files.state {
            alert.addButton(withTitle: "Open in Finder")
            if alert.runModal() == .alertSecondButtonReturn { files.openVolume() }
        } else {
            alert.runModal()
        }
    }

    // MARK: Status

    private func watchStatus() {
        var ctx = SCDynamicStoreContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, appName as CFString, { _, _, info in
            let me = Unmanaged<AppDelegate>.fromOpaque(info!).takeUnretainedValue()
            // The helper replaces the key by removing and re-adding it; let the
            // pair settle before redrawing so the icon doesn't flicker.
            NSObject.cancelPreviousPerformRequests(withTarget: me, selector: #selector(AppDelegate.refresh), object: nil)
            me.perform(#selector(AppDelegate.refresh), with: nil, afterDelay: 0.2, inModes: [.common])
        }, &ctx)
        guard let store else { return }
        SCDynamicStoreSetNotificationKeys(store, [statusKey] as CFArray, nil)
        let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    private enum State {
        case notInApplications, needsApproval, notRunning, waiting, connecting(String), connected([String: Any])
    }

    private var state: State {
        if !isInApplications { return .notInApplications }
        switch tethering.status {
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
        switch state {
        case .connected:
            button.image = cableGlyph
            button.appearsDisabled = false
        case .connecting, .waiting:
            button.image = cableGlyph
            button.appearsDisabled = true
        case .notInApplications, .needsApproval, .notRunning:
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: appName)
            button.image?.isTemplate = true
            button.appearsDisabled = false
        }
        // Rebuild an open menu in place, so plugging the phone in or switching
        // its mode shows up without reopening it.
        if menuIsOpen, let menu = statusItem.menu { menuNeedsUpdate(menu) }
    }

    private var menuIsOpen = false

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }

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
        func header(_ title: String) {
            if #available(macOS 14, *) {
                menu.addItem(.sectionHeader(title: title))
            } else {
                info(title)
            }
        }

        header("Phone")
        if phones.phones.isEmpty {
            info("No Android phone connected")
        }
        for phone in phones.phones {
            info("\(phone.name): \(phone.mode.title)")
        }
        _ = action("Which USB Mode Do I Need?…", #selector(showModeHelp))

        menu.addItem(.separator())
        header("USB Tethering")
        switch state {
        case .notInApplications:
            info("Move \(appName) to your Applications folder,")
            info("then open it from there to set up tethering")
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
            info("Tethering is turned off")
            _ = action("Turn On Tethering…", #selector(restartSetup))
        }
        _ = action("Show Log", #selector(openLog))

        menu.addItem(.separator())
        header("Files")
        switch files.state {
        case .noPhone:
            info("No phone in File transfer mode")
        case .needsMacFUSE:
            info("Showing your phone in Finder needs macFUSE")
            _ = action("Get macFUSE…", #selector(getMacFUSE))
        case .needsExtension:
            info("macFUSE is switched off")
            _ = action("Turn On macFUSE…", #selector(enableMacFUSE))
        case .mounting(let phone):
            info("Opening \(phone.name)…")
        case .mounted(let phone, _):
            info("\(phone.name) is in Finder")
            _ = action("Open in Finder", #selector(openVolume))
            _ = action("Eject \(phone.name)", #selector(ejectVolume))
        case .ejected(let phone):
            info("\(phone.name) is ejected")
            _ = action("Show in Finder", #selector(mountVolume))
        case .failed(let phone, let reason):
            info("Couldn’t open \(phone.name)")
            info(String(reason.prefix(60)))
            _ = action("Try Again", #selector(mountVolume))
            _ = action("Show Log", #selector(showMountLog))
        }
        let finder = action("Open Finder When Connected", #selector(toggleOpenInFinder))
        finder.state = files.openInFinder ? .on : .off

        menu.addItem(.separator())
        let login = action("Open at Login", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: Menu bar glyph

    /// The app icon's looped cable, redrawn as a single-colour template image.
    private lazy var cableGlyph: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            // Same curve as the app icon: a prolate trochoid loop rising at 45°.
            let a: CGFloat = 78, b: CGFloat = 150
            func rotate(_ p: NSPoint) -> NSPoint {
                let c = cos(CGFloat.pi / 4), s = sin(CGFloat.pi / 4)
                return NSPoint(x: p.x * c - p.y * s, y: p.x * s + p.y * c)
            }
            // Anchor the plug (6pt long, drawn below) so its tip sits in the top-right corner.
            let plugLength: CGFloat = 6
            let scale = rect.width / 860
            let base = rotate(NSPoint(x: a * .pi + 60, y: -2 * b))
            let anchor = NSPoint(x: rect.maxX - 1 - plugLength * cos(.pi / 4), y: rect.maxY - 1 - plugLength * sin(.pi / 4))
            func place(_ p: NSPoint) -> NSPoint {
                let r = rotate(p)
                return NSPoint(x: (r.x - base.x) * scale + anchor.x, y: (r.y - base.y) * scale + anchor.y)
            }

            let cable = NSBezierPath()
            cable.move(to: place(NSPoint(x: -a * .pi - 400, y: -2 * b)))
            for i in 0...200 {
                let t = -CGFloat.pi + 2 * .pi * CGFloat(i) / 200
                cable.line(to: place(NSPoint(x: a * t - b * sin(t), y: b * cos(t) - b)))
            }
            cable.line(to: place(NSPoint(x: a * .pi + 60, y: -2 * b)))
            cable.lineWidth = 1.6
            cable.lineCapStyle = .round
            cable.lineJoinStyle = .round
            NSColor.black.setStroke()
            cable.stroke()

            // Plug: overmold and metal shell along the cable's final heading.
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.translateBy(x: anchor.x, y: anchor.y)
            ctx.rotate(by: .pi / 4)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: -2, width: 3.4, height: 4), xRadius: 1, yRadius: 1).fill()
            NSBezierPath(roundedRect: NSRect(x: 3.8, y: -1.3, width: 2.2, height: 2.6), xRadius: 0.7, yRadius: 0.7).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = appName
        return image
    }()
}
