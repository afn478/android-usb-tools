# Android USB Tools

A macOS menu bar app for Android phones connected over USB. It does two
things, depending on the USB mode chosen on the phone:

- **USB tethering**: a userspace RNDIS driver, so Android tethering works
  without a kext, DriverKit entitlements, or touching SIP.
- **File transfer**: the phone's storage shows up in Finder as a volume you
  can browse, copy to and from, rename and delete in.

macOS ships drivers for CDC-ECM/NCM but not RNDIS, which is what most Android
phones use for USB tethering. The helper claims the phone's RNDIS interfaces
through `IOUSBHost`, speaks RNDIS on the endpoints, and bridges IPv4 to a `utun`
interface. ARP and DHCP are handled in-process, and the resulting network is
published to `configd`, so the default route and DNS get set up like any other
network.

## The app

Android USB Tools installs the tethering helper as a background service via
`SMAppService` and shows its state in the menu bar:

- cable icon: connected
- dimmed cable icon: waiting for a phone, or connecting
- warning icon: setup not finished, or tethering turned off

### Installing

```sh
make dmg        # builds build/AndroidUSBTools.dmg
```

Open the disk image and drag the app into Applications, then open it from
there. It asks you to switch it on under
System Settings → General → Login Items → Allow in the Background (Touch ID or
password). After that it starts at login and handles plug/unplug on its own.
To uninstall, move the app to the Trash; the helper notices and shuts down.

Logs go to `/var/log/rndis-tether.log`.

Signing uses the first “Apple Development” identity in the keychain; override
with `make SIGN_IDENTITY="..."`. Sharing the disk image with other Macs needs a
Developer ID certificate and notarization, or Gatekeeper will block it.

`make install` replaces the copy in /Applications and relaunches it, for
development.

## File transfer

When the phone is in File transfer (MTP) mode, the app mounts it at
`/Volumes/<phone name>` and opens it in Finder. Each storage (internal, SD card)
is a folder at the top. Eject it from Finder or the menu bar; unplugging also
unmounts it.

This needs [macFUSE](https://macfuse.github.io) (`brew install --cask
macfuse`), using its FSKit backend, so no kernel extension. Switch macFUSE on
once under System Settings → General → Login Items & Extensions → File System
Extensions: choose **By Category** at the top, since the switches in the "By
Application" view don't stay on (a macOS bug).

The MTP client in `mtp/` is native (`IOUSBHost`, protocol handling after
[go-mtpfs](https://github.com/hanwen/go-mtpfs)). Writing uses Android's MTP
edit extensions, so files are written in place rather than staged on the Mac.
Logs go to `~/Library/Logs/Android USB Tools/mtpfs.log`.

```sh
make mtp
build/mtp-probe                      # device info, storages, top-level folders
build/mtp-probe "Internal shared storage/DCIM"
build/mtp-probe -c "Internal shared storage/DCIM/Camera/clip.mp4"  # read + sha256
build/mtpfs /Volumes/Phone           # mount by hand (Ctrl-C unmounts)
```

`fskit/` holds a native FSKit module for the same volume, which would remove
the macFUSE dependency. It needs the FSKit entitlement, which Apple only
provisions for paid developer accounts.

## Running the tethering helper by hand

```sh
build/rndis-tether --probe -v   # no root: handshake + DHCP lease, then exit
sudo build/rndis-tether -v      # bring the link up in the foreground
```

`--no-primary` keeps other networks such as Wi-Fi ahead in the route order.

## Limitations

- File transfer: one phone at a time. Folder listings come from the phone and
  are cached for a few seconds, so changes made on the phone show up after
  that. Very large folders (thousands of files) are slow in Finder.
- IPv4 only; IPv6 from the phone is ignored.
- The link appears as `utunN`, not as an Ethernet service in System Settings.
