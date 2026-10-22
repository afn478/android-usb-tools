// Notices Android phones on USB and which USB mode each is in, from the
// interfaces it exposes. Used for the menu's status line and the help dialog.

import Foundation
import IOKit
import IOKit.usb

final class PhoneWatcher {
    enum Mode {
        case fileTransfer, photos, tethering, midi, noData

        var title: String {
            switch self {
            case .fileTransfer: return "File transfer"
            case .photos: return "PTP (photos only)"
            case .tethering: return "USB tethering"
            case .midi: return "MIDI"
            case .noData: return "Charging only"
            }
        }
    }

    struct Phone {
        let name: String
        let mode: Mode
    }

    private(set) var phones: [Phone] = []

    // Phone makers' USB vendor IDs, for phones that expose no interfaces at
    // all while only charging.
    private static let androidVendors: Set<Int> = [
        0x18D1,  // Google
        0x04E8,  // Samsung
        0x2A70,  // OnePlus
        0x22D9,  // OPPO, also newer OnePlus
        0x2717,  // Xiaomi
        0x22B8,  // Motorola
        0x0FCE,  // Sony
        0x12D1,  // Huawei
        0x0BB4,  // HTC
        0x1004,  // LG
        0x2D95,  // vivo
        0x2B4C,  // Nothing
    ]

    private let onChange: () -> Void
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start() {
        port = IONotificationPortCreate(kIOMainPortDefault)
        guard let port else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
        let me = Unmanaged.passUnretained(self).toOpaque()
        // Interfaces show up a moment after their device, and change when the
        // phone switches mode, so watch both.
        for cls in ["IOUSBHostDevice", "IOUSBHostInterface"] {
            for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
                var it: io_iterator_t = 0
                IOServiceAddMatchingNotification(port, type, IOServiceMatching(cls), { ctx, it in
                    let watcher = Unmanaged<PhoneWatcher>.fromOpaque(ctx!).takeUnretainedValue()
                    watcher.drain(it)
                    watcher.scheduleScan()
                }, me, &it)
                iterators.append(it)
                drain(it)
            }
        }
        scan()
    }

    private func drain(_ it: io_iterator_t) {
        while case let svc = IOIteratorNext(it), svc != 0 { IOObjectRelease(svc) }
    }

    private var pendingScan: DispatchWorkItem?

    private func scheduleScan() {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func scan() {
        var found: [Phone] = []
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &it) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(it) }
        while case let dev = IOIteratorNext(it), dev != 0 {
            defer { IOObjectRelease(dev) }
            if let phone = phone(for: dev) { found.append(phone) }
        }
        phones = found
        onChange()
    }

    private func phone(for dev: io_service_t) -> Phone? {
        var mode: Mode?
        var android = false
        var otherInterfaces = 0
        var children: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(dev, kIOServicePlane, &children) == KERN_SUCCESS {
            while case let child = IOIteratorNext(children), child != 0 {
                defer { IOObjectRelease(child) }
                guard IOObjectConformsTo(child, "IOUSBHostInterface") != 0 else { continue }
                let cls = number(child, "bInterfaceClass"), sub = number(child, "bInterfaceSubClass"),
                    proto = number(child, "bInterfaceProtocol")
                let name = string(child, "kUSBString")
                switch (cls, sub, proto) {
                case (0x06?, 0x01?, 0x01?), (0xFF?, 0xFF?, 0x00?):
                    if name == "MTP" { mode = .fileTransfer; android = true }
                    if name == "PTP" { mode = mode ?? .photos; android = true }
                case (0xE0?, 0x01?, 0x03?), (0xEF?, 0x04?, 0x01?), (0x0A?, _, _):
                    // RNDIS control (two variants), and its data interface
                    if cls != 0x0A { mode = .tethering; android = true }
                case (0x01?, _, _):
                    mode = mode ?? .midi
                case (0xFF?, 0x42?, 0x01?):
                    android = true  // ADB, alongside whatever mode is chosen
                    continue
                default:
                    break
                }
                otherInterfaces += 1
            }
            IOObjectRelease(children)
        }
        // A phone that's only charging exposes nothing (or just ADB); requiring
        // that keeps the same makers' drives and monitors out.
        if !android, otherInterfaces == 0, let vendor = number(dev, "idVendor"), Self.androidVendors.contains(vendor) {
            android = true
        }
        guard android else { return nil }
        return Phone(name: string(dev, "kUSBProductString") ?? "Android phone", mode: mode ?? .noData)
    }

    private func number(_ svc: io_service_t, _ key: String) -> Int? {
        (IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?
            .intValue
    }

    private func string(_ svc: io_service_t, _ key: String) -> String? {
        IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }
}
