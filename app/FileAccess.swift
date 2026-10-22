// Mounts phones that are in File transfer mode, using the bundled mtpfs and
// macFUSE's FSKit backend.
//
// mtpfs has to run as the logged-in user: FSKit extensions are enabled per
// user, so a root mount wouldn't find macFUSE's.

import AppKit
import IOKit
import IOKit.usb

private let macFUSEPath = "/Library/Filesystems/macfuse.fs"
private let logDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Android USB Tools", isDirectory: true)

final class FileAccess {
    struct Phone: Equatable {
        let serial: String
        let name: String
    }

    enum State: Equatable {
        case noPhone
        case needsMacFUSE
        case needsExtension
        case mounting(Phone)
        case mounted(Phone, URL)
        case ejected(Phone)
        case failed(Phone, String)
    }

    private(set) var state: State = .noPhone {
        didSet { if state != oldValue { onChange() } }
    }

    var openInFinder: Bool {
        get { UserDefaults.standard.object(forKey: "openFinderOnMount") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "openFinderOnMount") }
    }

    static var logURL: URL { logDirectory.appendingPathComponent("mtpfs.log") }

    private let onChange: () -> Void
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var phone: Phone?
    private var process: Process?
    private var attempts = 0

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        port = IONotificationPortCreate(kIOMainPortDefault)
        guard let port else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let me = Unmanaged.passUnretained(self).toOpaque()
        // Android names its MTP interface "MTP"; current phones use the still
        // image class, older ones a vendor class.
        for (cls, sub, proto) in [(6, 1, 1), (255, 255, 0)] {
            for (type, added) in [(kIOFirstMatchNotification, true), (kIOTerminatedNotification, false)] {
                let match = IOServiceMatching("IOUSBHostInterface") as NSMutableDictionary
                match["bInterfaceClass"] = cls
                match["bInterfaceSubClass"] = sub
                match["bInterfaceProtocol"] = proto
                var it: io_iterator_t = 0
                let callback: IOServiceMatchingCallback = added
                    ? { ctx, it in Unmanaged<FileAccess>.fromOpaque(ctx!).takeUnretainedValue().interfacesAdded(it) }
                    : { ctx, it in Unmanaged<FileAccess>.fromOpaque(ctx!).takeUnretainedValue().interfacesRemoved(it) }
                IOServiceAddMatchingNotification(port, type, match, callback, me, &it)
                iterators.append(it)
                // Arms the notification and reports what is already attached.
                added ? interfacesAdded(it) : drain(it)
            }
        }
    }

    // MARK: Actions

    func mount() {
        guard let phone else { return }
        attempts = 0
        launch(phone)
    }

    func eject() {
        guard case .mounted(let phone, _) = state else { return }
        // mtpfs unmounts and exits on SIGTERM.
        process?.terminate()
        state = .ejected(phone)
    }

    func openVolume() {
        if case .mounted(_, let url) = state { NSWorkspace.shared.open(url) }
    }

    /// Asks mtpfs to unmount on quit. Waits briefly rather than with
    /// waitUntilExit, which can hang the quit when the exit notification has
    /// already gone by; mtpfs also exits by itself once the app is gone.
    func stop() {
        guard let p = process, p.isRunning else { return }
        let pid = p.processIdentifier
        p.terminate()
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0, Date() < deadline { usleep(50_000) }
    }

    // MARK: Device notifications

    private func interfacesAdded(_ it: io_iterator_t) {
        while case let svc = IOIteratorNext(it), svc != 0 {
            defer { IOObjectRelease(svc) }
            guard string(svc, "kUSBString") == "MTP", let found = phoneFor(svc) else { continue }
            guard phone == nil else { continue }  // one phone at a time
            phone = found
            attempts = 0
            launch(found)
        }
    }

    private func interfacesRemoved(_ it: io_iterator_t) {
        drain(it)
        // mtpfs notices the unplug itself and unmounts; here only forget the
        // phone so an eject doesn't stick to the next connection.
        phone = nil
        if process == nil { state = .noPhone }
    }

    private func drain(_ it: io_iterator_t) {
        while case let svc = IOIteratorNext(it), svc != 0 { IOObjectRelease(svc) }
    }

    private func string(_ svc: io_service_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }

    private func phoneFor(_ iface: io_service_t) -> Phone? {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(iface, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }
        guard let serial = string(parent, "kUSBSerialNumberString") else { return nil }
        return Phone(serial: serial, name: string(parent, "kUSBProductString") ?? "Android Phone")
    }

    // MARK: mtpfs

    private func launch(_ phone: Phone) {
        guard FileManager.default.fileExists(atPath: macFUSEPath) else {
            state = .needsMacFUSE
            return
        }
        guard process == nil, let exe = Bundle.main.url(forAuxiliaryExecutable: "mtpfs") else { return }
        let mountPoint = freeMountPoint(for: phone.name)
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Self.logURL.path) {
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        }
        let log = try? FileHandle(forWritingTo: Self.logURL)
        log?.seekToEndOfFile()

        let p = Process()
        p.executableURL = exe
        p.arguments = ["-s", phone.serial, mountPoint.path]
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.exited(proc, phone: phone) }
        }
        do {
            try p.run()
        } catch {
            state = .failed(phone, error.localizedDescription)
            return
        }
        process = p
        state = .mounting(phone)
        waitForMount(mountPoint, phone: phone, process: p)
    }

    /// /Volumes/<name> with dashes for spaces (macFUSE's FSKit mount fails on
    /// paths with spaces; Finder shows the volume name, not the folder's), or
    /// <name>-2 … when something else uses it. An empty folder left behind by
    /// an earlier mount is reused, since only root can remove it.
    private func freeMountPoint(for name: String) -> URL {
        let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        let clean = name.components(separatedBy: CharacterSet(charactersIn: " /")).joined(separator: "-")
        for i in 1... {
            let url = volumes.appendingPathComponent(i == 1 ? clean : "\(clean)-\(i)", isDirectory: true)
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return url }
            if contents.isEmpty && !isMountPoint(url) { return url }
        }
        fatalError("unreachable")
    }

    private func waitForMount(_ url: URL, phone: Phone, process p: Process, tries: Int = 0) {
        guard process === p, p.isRunning else { return }
        if isMountPoint(url) {
            attempts = 0
            state = .mounted(phone, url)
            if openInFinder { NSWorkspace.shared.open(url) }
            return
        }
        guard tries < 100 else { return }  // keep the spinner; mtpfs logs why
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitForMount(url, phone: phone, process: p, tries: tries + 1)
        }
    }

    private func isMountPoint(_ url: URL) -> Bool {
        var fs = statfs()
        guard statfs(url.path, &fs) == 0 else { return false }
        let mountedOn = withUnsafePointer(to: &fs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return mountedOn == url.path
    }

    private func exited(_ p: Process, phone: Phone) {
        guard process === p else { return }
        process = nil
        // mtpfs pauses Image Capture's ptpcamerad while mounted and resumes it
        // on exit; make sure of that even if it crashed.
        if p.terminationReason == .uncaughtSignal { resumeImageCapture() }
        let stillConnected = self.phone == phone
        if case .ejected = state { return }
        if p.terminationStatus == 0 {
            // Ejected from Finder, or the phone went away.
            state = stillConnected ? .ejected(phone) : .noPhone
            return
        }
        guard stillConnected else {
            state = .noPhone
            return
        }
        let reason = lastLogLine() ?? "mtpfs exited with status \(p.terminationStatus)"
        if reason.contains("extension not enabled") {
            state = .needsExtension
            return
        }
        // The phone's MTP service can take a moment after the mode switch.
        attempts += 1
        if attempts < 3 {
            state = .mounting(phone)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.phone == phone, self.process == nil else { return }
                self.launch(phone)
            }
        } else {
            state = .failed(phone, reason)
        }
    }

    private func resumeImageCapture() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-CONT", "-x", "-U", String(getuid()), "ptpcamerad"]
        try? pkill.run()
    }

    private func lastLogLine() -> String? {
        guard let data = try? Data(contentsOf: Self.logURL), let text = String(data: data.suffix(4096), encoding: .utf8)
        else { return nil }
        return text.split(separator: "\n").last.map(String.init)
    }
}
