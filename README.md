# rndis-tether

Userspace RNDIS driver for macOS, so Android USB tethering works without a kext,
DriverKit entitlements, or touching SIP.

macOS ships drivers for CDC-ECM/NCM but not RNDIS, which is what most Android
phones use for USB tethering. The helper claims the phone's RNDIS interfaces
through `IOUSBHost`, speaks RNDIS on the endpoints, and bridges IPv4 to a `utun`
interface. ARP and DHCP are handled in-process, and the resulting network is
published to `configd`, so the default route and DNS get set up like any other
network.

## Tether.app

A menu bar app that installs the helper as a launchd daemon via `SMAppService`
and shows its state:

- hotspot icon: connected
- dimmed hotspot icon: waiting for a phone, or connecting
- warning icon: helper not approved or not running

```sh
make            # builds and signs build/Tether.app
make install    # copies it to /Applications and launches it
```

On first launch, approve “Tether” under System Settings → General → Login Items
→ Allow in the Background. After that the helper starts at boot and handles
plug/unplug on its own. Logs go to `/var/log/rndis-tether.log`.

Signing uses the first “Apple Development” identity in the keychain; override
with `make SIGN_IDENTITY="..."`.

## Running the helper by hand

```sh
build/rndis-tether --probe -v   # no root: handshake + DHCP lease, then exit
sudo build/rndis-tether -v      # bring the link up in the foreground
```

`--no-primary` keeps other networks such as Wi-Fi ahead in the route order.

## Limitations

- IPv4 only; IPv6 from the phone is ignored.
- The link appears as `utunN`, not as an Ethernet service in System Settings.
