# macdroid-tether-extreme

**Android USB tethering on modern macOS — in userspace. No kernel extension, no SIP changes, no App Store app.**

Plug an Android phone into a Mac, turn on USB tethering, run one command, and get a native network connection over the cable at full speed. Works on Apple Silicon.

```
sudo ./macdroid-tether-extreme --default-route
```

---

## Why this exists

When an Android phone enables "USB tethering," it speaks **RNDIS** (Microsoft's *Remote NDIS* — Ethernet tunneled over USB). Windows and Linux ship an RNDIS host driver. **macOS never has.** Plug in an Android phone and it shows up in Network settings as a device the Mac has no idea how to talk to — `SAMSUNG_Android — Not connected` — and just sits there. (iPhone USB tethering works, because Apple wrote a driver for it; Android's RNDIS gets nothing.)

For years the fix was [**HoRNDIS**](https://github.com/jwise/horndis), a kernel extension that added the missing driver. It's dead:

- **x86-only** — never built for `arm64e`, so it can't load on Apple Silicon at all.
- **Kexts are over** — Apple has been dismantling third-party kernel extensions since 2019; recent macOS releases removed hooks HoRNDIS depended on.

`macdroid-tether-extreme` does the same job HoRNDIS did, but entirely in **userspace** — so none of the kernel-extension problems apply. No `arm64e` kext signing, no reduced security, no reboots.

## How it works (high level)

The whole thing is one C file. It uses two ordinary building blocks:

- **[libusb](https://libusb.info/)** to talk to the phone's RNDIS endpoint directly from userspace.
- **utun** (macOS's userspace tunnel device) to hand packets to the network stack.

```
your apps  →  utun interface  →  macdroid-tether-extreme  →  libusb  →  phone (RNDIS)  →  5G
                                  └── wraps/unwraps packets, runs DHCP, answers ARP ──┘
```

On startup it opens the phone's USB control + data interfaces, runs the RNDIS handshake (init → query MAC → set packet filter), then pumps traffic: read an IP packet from `utun`, wrap it in Ethernet + an RNDIS header, write it to the phone's bulk USB endpoint, and the reverse inbound. A tiny built-in DHCP client gets an IP from the phone, and an ARP responder keeps the link addressable.

**Full write-up with the architecture, packet diagrams, and the debugging story:** [`problem-statement.html`](problem-statement.html) (open it in a browser).

## Requirements

- Apple Silicon or Intel Mac, macOS 11+
- [libusb](https://libusb.info/): `brew install libusb`
- An Android phone (developed and tested against a Samsung Galaxy Z Flip, Android 16 / One UI)

## Build

```sh
make
```

Produces a ~54 KB binary, `macdroid-tether-extreme`. (Note: if your shell aliases `cc`, the Makefile calls `clang` explicitly.)

## Use

1. Plug in the phone and enable **USB tethering** from Settings → Connections → Mobile Hotspot and Tethering. (This leaves the phone in RNDIS mode — exactly what this tool wants.)
2. Run it:
   ```sh
   sudo ./macdroid-tether-extreme --default-route
   ```
   Root is required to create the `utun` interface and claim the USB device.
3. Turn off Wi-Fi. All traffic now flows over USB.
4. Press **Ctrl+C** to stop — it restores your previous default route and DNS and tears down the interface.

### Options

| Flag | Effect |
|---|---|
| *(none)* | **Probe/test mode.** Runs the RNDIS handshake + DHCP and adds a route for `1.1.1.1` only, so it won't touch your existing routes. `ping 1.1.1.1` to verify. |
| `--default-route` | Route **all** traffic through the phone, and register the phone's DNS with the system resolver. |
| `--mtu <n>` | Set the interface MTU (default 1500). **Use `--mtu 1400` if a VPN is running on the phone** — otherwise large packets get black-holed and throughput collapses. |

Without root, the tool runs in probe mode automatically (handshake + DHCP, no interface setup) — handy for testing that the USB path works.

## Gotchas

- **Don't use `adb shell svc usb setFunctions` to force NCM.** It creates a zombie network interface on the phone; Android then serves DHCP on the dead interface while the live one stays down, and no data flows. Enable tethering through the Settings UI only. If you've already done it and hit `NO-CARRIER`, reboot the phone.
- **Keep the terminal open while tethering** — the process *is* the driver. Closing it drops the connection (cleanly).
- **Carrier hotspot limits still apply.** This is normal NAT tethering; carriers can detect and meter it (TTL, OS fingerprinting). A VPN on the phone mitigates detection — pair it with `--mtu 1400`.

## Measured

On a Galaxy Z Flip over 5G: **~260 Mbps** down, **~16 ms** latency, verified end-to-end (TCP/TLS/DNS) with Wi-Fi off.

## License

MIT
