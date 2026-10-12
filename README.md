# MacDroid

**Use your Android phone's own mobile data as your Mac's internet over the USB cable, without it counting as hotspot or tethering.**

Every app on the Mac goes through the phone, including browsers, terminals, Slack and video calls, over both TCP and UDP. Nothing needs installing on the phone, root isn't needed, and if anything crashes nothing is left behind.

```sh
./macdroid.sh setup            # once
sudo ./macdroid.sh install     # once
./macdroid.sh toggle           # on / off, no password (or use Raycast)
```

> **Educational and research use.** Use it with your own devices and in line with your carrier's terms.

For a visual walkthrough, open [`how-it-works.html`](how-it-works.html) in a browser.

---

## How it works

```
Mac apps ─▶ utun225 (sing-box tun) ─▶ SOCKS5 + UDP-over-TCP ─▶ adb forward ─▶ USB cable
        ─▶ phone: sing-box SOCKS server, started via `adb shell` ─▶ phone's mobile data
```

1. **On the phone:** `macdroid.sh` copies a [sing-box](https://sing-box.sagernet.org) binary to `/data/local/tmp` and runs it through `adb shell` as a small SOCKS server. It listens only on the phone's own localhost, so nothing is exposed on the phone's Wi-Fi.
2. **On the cable:** `adb forward` connects Mac `127.0.0.1:8901` to the phone's server over USB.
3. **On the Mac:** a second sing-box creates the `utun225` network interface and routes the whole internet into it. It sends every connection down the cable to the phone.
4. The phone's server opens each connection itself, through its normal mobile-data connection.

### Why it isn't hotspot or tethering

Hotspot and USB tethering are Android features that forward *another device's* packets. Here, neither is used. The connections are opened by a normal process on the phone, the same path any app uses. The phone itself reports this:

| Checked on the phone (`adb shell dumpsys …`) | Result |
|---|---|
| Tethering upstream | `null`. Tethering is off. |
| Tethering interfaces (rndis / ncm / hotspot) | none |
| Data Android counts as tethering (uid −5) | none |
| Data counted to our process (shell, uid 2000) | all of it, as normal on-device use |

The carrier sees the phone's own connections on its normal data connection. One honest caveat: the *content* still comes from a Mac, so a carrier that inspects traffic in depth (TLS fingerprints, user-agents) could tell. The real proof is your carrier's own **hotspot usage** counter. Note it before a long session and check that it hasn't moved.

### UDP works (DNS, QUIC, calls)

`adb forward` only carries TCP. sing-box's **UDP-over-TCP** sends each UDP flow inside the TCP connection to the phone, and the phone's server unpacks it. So DNS, QUIC/HTTP3, NTP, video calls and Tailscale's WireGuard all work, not just web pages.

### DNS, and Tailscale MagicDNS

The Mac's sing-box answers every DNS lookup itself:

- **Public names** go over encrypted DNS (DoH) to `1.1.1.1`, through the phone.
- **`*.ts.net` names** go to Tailscale's own resolver, `100.100.100.100`, so MagicDNS (`ssh cloudy`) keeps working. Tailscale's settings are never changed.

A small helper, [`macdroid/dnshold.c`](macdroid/dnshold.c), makes this the Mac's first-choice resolver, ahead of Tailscale. It also marks MacDroid as macOS's **primary** connection. Without that, macOS thinks you're offline whenever Wi-Fi is off, and Chrome shows `ERR_INTERNET_DISCONNECTED` even though traffic would flow.

DNS answers are IPv4 only. All IPv6 traffic is still routed into the tunnel, so none of it leaks around the phone.

### Routing

sing-box adds routes that cover the whole internet. They're more specific than the normal default route, so turning Wi-Fi on or off can't take traffic back. Your LAN (192.168.x and similar) and your tailnet (`100.64.0.0/10`) stay direct whenever they're reachable.

---

## Requirements

- An Apple Silicon Mac. Xcode Command Line Tools are needed for `setup`, which compiles the small helper.
- `adb`: `brew install --cask android-platform-tools`
- An Android phone with **USB debugging** on and this Mac allowed (`adb devices` shows `device`). Tested on a Galaxy Z Flip6 with Android 16 on T-Mobile.
- Turn the **phone's** Wi-Fi off if you want mobile data. The Mac's Wi-Fi can be on or off.

You don't need root on the phone, a proxy app, or USB tethering.

## Setup

```sh
./macdroid.sh setup           # downloads sing-box 1.14.3 (Mac + Android), builds dnshold, copies to the phone
sudo ./macdroid.sh install    # installs the on/off switch (see below), once
```

### What `install` does

You need the password once, here. After that, turning it on and off needs none:

- It copies everything, **root-owned**, to `/Library/PrivilegedHelperTools/macdroid/`.
- It registers the launchd job `com.macdroid`, which **never starts at boot**, only when you turn it on. launchd runs it in the background, so no Terminal window needs to stay open.
- It adds `/etc/sudoers.d/macdroid`, which lets your user run exactly two commands without a password: start that job and stop it.

The rule can't be used to run anything else as root. Every file the job runs is root-owned, and when running as root the script only uses system binaries. adb and tailscale run as your user.

Re-run `sudo ./macdroid.sh install` after changing anything in this repo. `sudo ./macdroid.sh uninstall` removes all three.

## Usage

| Command | sudo | What it does |
|---|---|---|
| `./macdroid.sh toggle` | no | On if off, off if on |
| `./macdroid.sh start` / `stop` | no | Explicit on / off. `start` waits until it's verified. |
| `./macdroid.sh status` | no | One line: `📱 MacDroid ON · 140ms · exit 172.56.x.x` or `⚪ OFF` |
| `./macdroid.sh check` | no | Full diagnosis: exit IP matches the phone's, DNS, real UDP, primary connection, MagicDNS |
| `sudo ./macdroid.sh up` | yes | Foreground mode for debugging. That window is the switch, and Ctrl+C turns it off. |
| `sudo ./macdroid.sh down` | yes | Force teardown from any terminal |

**Raycast:** `~/repos/raycast-scripts` has **MacDroid Toggle** and an inline **MacDroid Status** line that refreshes every 30 seconds. Both call the installed copy.

### Checking it's really working

```
$ ./macdroid.sh check
  ✓ transport   exit 172.56.161.6 = phone's exit (114ms)
  ✓ DNS         names resolve (resolver #1: 172.19.0.2)
  ✓ UDP         NTP round-trip 52ms (non-DNS UDP)
  ✓ primary     macOS sees utun225 as the main connection (Chrome etc. won't say offline)
  ✓ MagicDNS    tabishs-macbook-pro.tail463fec.ts.net resolves
```

The key line is `exit … = phone's exit`. It means the Mac's public IP is the phone's mobile-data IP. `ping` isn't a valid test, because ICMP isn't carried. Use `check`.

## Crash safety

Nothing outlives the processes that own it:

- **Routes** belong to `utun225`. The kernel deletes them when sing-box exits.
- **DNS** is a *temporary* macOS setting held by `dnshold`. macOS deletes it when `dnshold` exits, even on `kill -9`.
- **The phone server** runs inside an `adb shell` session and dies with it.
- **Tailscale** settings are never touched.

A reboot is never needed to recover. If the cable is unplugged and plugged back in, the phone side restarts on its own within a few seconds.

Logs: `/tmp/macdroid.log` for events, and `/tmp/macdroid.out` for the launchd job's output. While running, per-process logs are in `/tmp/macdroid/`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `adb devices` is empty, but the phone charges | USB debugging is off. On Samsung, **Auto Blocker** (Settings → Security and privacy) blocks it even when the toggle is on. Turn it off, replug, and choose **Transferring files**. |
| `adb devices` says `unauthorized` | Unlock the phone, tap **Allow** on "Allow USB debugging?", and tick "Always allow". |
| `📵 Phone not on adb` | As above. Check the cable too. |
| Exit IP is the phone's but slow | That's the phone's own signal and plan. The USB link moves over 2 Gbit/s and isn't the bottleneck. |
| `up` warns the phone is on Wi-Fi | Turn the phone's Wi-Fi off, or you'll be using that Wi-Fi rather than mobile data. |
| An app says offline | Run `./macdroid.sh check` and look at the `primary` line. |
| Anything stuck | `sudo ./macdroid.sh down`. Even a crash cleans up after itself (see above). |

## Layout

| Path | What |
|---|---|
| `macdroid.sh` | Everything: setup, install, on/off, checks |
| `macdroid/mac.json` | Mac sing-box config: tun, routes, DNS, phone outbound (UDP-over-TCP) |
| `macdroid/phone.json` | Phone sing-box config: SOCKS server on phone localhost, DoH resolver |
| `macdroid/dnshold.c` | Holds the DNS + primary-service registration for as long as it runs |
| `how-it-works.html` | Visual explainer |

## History

Earlier versions of this repo took two other routes. Both are removed but still in git history:

1. **A userspace RNDIS driver** (`macdroid_tether_extreme.c`). It was a HoRNDIS replacement that made Android USB tethering work on Apple Silicon. It worked, but tethering *is* the hotspot meter.
2. **Every Proxy + `mooch.sh`** (with a tun2socks transparent mode). It used the on-device data path, but `adb forward` only carries TCP, so DNS and all other UDP failed whenever Wi-Fi was off.

## License

MIT
