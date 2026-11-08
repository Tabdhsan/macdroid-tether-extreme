# MacDroid

**Use your phone's own mobile data, Android or iPhone, as your Mac's internet over the USB cable, without it counting as hotspot or tethering.**

Every app on the Mac goes through the phone, including browsers, terminals, Slack and video calls, over both TCP and UDP. On Android nothing needs installing on the phone; on iPhone you install one App Store app. No root or jailbreak, and if anything crashes nothing is left behind. MacDroid picks Android or iPhone by what's plugged in.

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

### On an iPhone

The Mac side is identical. Only the two phone-facing pieces change, because iOS has no `adb shell`:

```
Mac apps ─▶ utun225 ─▶ SOCKS5 + UDP-over-TCP ─▶ iproxy (usbmuxd) ─▶ USB cable
        ─▶ iPhone: sing-box MT app, SOCKS server on the phone's localhost ─▶ mobile data
```

- **The phone server** is the [sing-box MT](https://apps.apple.com/app/sing-box-mt/id6785326793) app (the iOS app linked from [sing-box's own site](https://sing-box.sagernet.org/clients/apple/)), running [`macdroid/iphone.json`](macdroid/iphone.json): the same SOCKS server as `phone.json`, with no VPN interface, so the phone's own traffic is untouched. iOS keeps it running in the background because it's a VPN-type app. You start it on the phone; the script can't.
- **The cable hop** is `iproxy` (libimobiledevice), forwarding Mac `127.0.0.1:8901` to the phone's port 1090 over Apple's usbmuxd, in place of `adb forward`.
- **iOS runs one VPN-type app at a time**, so starting sing-box MT turns off the iPhone's own Tailscale (and vice versa). The Mac's Tailscale is unaffected.
- **Never use Personal Hotspot or the "iPhone USB" network service.** That's tethering.

### Why it isn't hotspot or tethering

Hotspot and USB tethering are Android features that forward *another device's* packets. Here, neither is used. The connections are opened by a normal process on the phone, the same path any app uses. The phone itself reports this:

| Checked on the phone (`adb shell dumpsys …`) | Result |
|---|---|
| Tethering upstream | `null`. Tethering is off. |
| Tethering interfaces (rndis / ncm / hotspot) | none |
| Data Android counts as tethering (uid −5) | none |
| Data counted to our process (shell, uid 2000) | all of it, as normal on-device use |

On an iPhone the same is true by construction (the connections are opened by the sing-box MT app on the phone), but iOS has no equivalent of `dumpsys` to show it.

The carrier sees the phone's own connections on its normal data connection. One honest caveat: the *content* still comes from a Mac, so a carrier that inspects traffic in depth (TLS fingerprints, user-agents) could tell. The real proof is your carrier's own **hotspot usage** counter. Note it before a long session and check that it hasn't moved.

### UDP works (DNS, QUIC, calls)

`adb forward` and `iproxy` only carry TCP. sing-box's **UDP-over-TCP** sends each UDP flow inside the TCP connection to the phone, and the phone's server unpacks it. So DNS, QUIC/HTTP3, NTP, video calls and Tailscale's WireGuard all work, not just web pages.

### DNS, and Tailscale MagicDNS

The Mac's sing-box answers every DNS lookup itself:

- **Public names** go over encrypted DNS (DoH) to `1.1.1.1`, through the phone.
- **`*.ts.net` names** go to Tailscale's own resolver, `100.100.100.100`, so MagicDNS (`ssh my-server`) keeps working. Tailscale's settings are never changed.

A small helper, [`macdroid/dnshold.c`](macdroid/dnshold.c), makes this the Mac's first-choice resolver, ahead of Tailscale. It also marks MacDroid as macOS's **primary** connection. Without that, macOS thinks you're offline whenever Wi-Fi is off, and Chrome shows `ERR_INTERNET_DISCONNECTED` even though traffic would flow.

**Tailscale with the Mac's Wi-Fi off.** On macOS, Tailscale ignores every `utun` interface when it decides whether there's a network at all, and MacDroid's tunnel is `utun225`. With Wi-Fi off it would say "Network Down" and the tailnet would stop working. So while MacDroid is on, it also creates `feth225`, a placeholder interface with a dead-end address (`198.18.225.1`). Tailscale counts that as a network and comes back online. Its traffic still goes through `utun225` and the phone; nothing is sent over the placeholder.

DNS answers are IPv4 only. All IPv6 traffic is still routed into the tunnel, so none of it leaks around the phone.

### Routing

sing-box adds routes that cover the whole internet. They're more specific than the normal default route, so turning Wi-Fi on or off can't take traffic back. Your LAN (192.168.x and similar) and your tailnet (`100.64.0.0/10`) stay direct whenever they're reachable.

---

## Requirements

- An Apple Silicon Mac. Xcode Command Line Tools are needed for `setup`, which compiles the small helper.
- `adb`: `brew install --cask android-platform-tools`
- **Android:** any 64-bit phone with **USB debugging** on and this Mac allowed (`adb devices` shows `device`). Tested on a Galaxy Z Flip6 with Android 16 on T-Mobile.
- **iPhone:** any iPhone that trusts this Mac, with `brew install libimobiledevice` on the Mac and the **sing-box MT** app on the phone. Tested on iOS 27.2 on T-Mobile.
- Turn the **phone's** Wi-Fi off if you want mobile data. The Mac's Wi-Fi can be on or off.

You don't need root, a jailbreak, or USB tethering.

## Setup

```sh
./macdroid.sh setup           # downloads sing-box 1.14.3 (Mac + Android), builds dnshold, copies to an Android phone
sudo ./macdroid.sh install    # installs the on/off switch (see below), once
```

**iPhone, once per phone:**

1. Plug in and tap **Trust This Computer**.
2. Install [sing-box MT](https://apps.apple.com/app/sing-box-mt/id6785326793) (app ID 6785326793) from the App Store.
3. AirDrop `macdroid/iphone.json` to the phone, open it in sing-box MT, and name the profile `MacDroid`.
4. Select that profile and tap **Start**. Allow the VPN configuration the first time.

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
| `./macdroid.sh check` | no | Full diagnosis: exit IP matches the phone's, DNS, real UDP, primary connection, Tailscale online, MagicDNS |
| `sudo ./macdroid.sh up` | yes | Foreground mode for debugging. That window is the switch, and Ctrl+C turns it off. |
| `sudo ./macdroid.sh down` | yes | Force teardown from any terminal |

### Everyday routine

**Turn it on:** plug in the phone, turn the phone's Wi-Fi off, on an iPhone start the MacDroid profile in sing-box MT, then **MacDroid Toggle** in Raycast. The Mac's Wi-Fi can stay on.

**Back to normal:** **MacDroid Toggle** in Raycast (or just unplug; it turns itself off after 15 seconds), turn the phone's Wi-Fi back on, and on an iPhone tap **Stop** in sing-box MT so the phone's own VPN slot (Tailscale) is free again.

**Raycast:** `~/repos/custom-raycast/scripts` has **MacDroid Toggle** and an inline **MacDroid Status** line that refreshes every 30 seconds. Both call the installed copy.

### Checking it's really working

```
$ ./macdroid.sh check
  ✓ transport   exit 172.56.161.6 = phone's exit (114ms)
  ✓ DNS         names resolve (resolver #1: 172.19.0.2)
  ✓ UDP         NTP round-trip 52ms (non-DNS UDP)
  ✓ primary     macOS sees utun225 as the main connection (Chrome etc. won't say offline)
  ✓ Tailscale   this Mac is online on the tailnet
  ✓ MagicDNS    my-mac.example-tailnet.ts.net resolves
```

The key line is `exit … = phone's exit`. It means the Mac's public IP is the phone's mobile-data IP. `ping` isn't a valid test, because ICMP isn't carried. Use `check`.

## Crash safety

Nothing outlives the processes that own it:

- **Routes** belong to `utun225`. The kernel deletes them when sing-box exits.
- **DNS** is a *temporary* macOS setting held by `dnshold`. macOS deletes it when `dnshold` exits, even on `kill -9`.
- **The phone server** runs inside an `adb shell` session and dies with it. On iPhone, MacDroid only owns `iproxy`, which it stops; the sing-box MT app keeps running until you tap Stop, and on its own it only listens on the phone's localhost.
- **Tailscale** settings are never touched.
- **The `feth225` placeholder** is the one thing not owned by a process. Teardown removes it, and so does the next start if a crash left it behind. Left over, it's harmless: one address and no routes.

A reboot is never needed to recover.

**Unplugging:** if you plug the phone back in within 15 seconds, the phone side restarts on its own and MacDroid stays on. If the phone stays unplugged longer, MacDroid turns itself off (the same clean teardown), so the Mac falls back to Wi-Fi rather than routing into a dead tunnel. Change the window with `UNPLUG_GRACE` in `macdroid.sh`.

Logs: `/tmp/macdroid.log` for events, and `/tmp/macdroid.out` for the launchd job's output. While running, per-process logs are in `/tmp/macdroid/`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `adb devices` is empty, but the phone charges | USB debugging is off. On Samsung, **Auto Blocker** (Settings → Security and privacy) blocks it even when the toggle is on. Turn it off, replug, and choose **Transferring files**. |
| `adb devices` says `unauthorized` | Unlock the phone, tap **Allow** on "Allow USB debugging?", and tick "Always allow". |
| `📵 No phone` | As above, or on iPhone: unlock it and tap **Trust**. Check the cable too. |
| `iPhone found but sing-box isn't answering` | Open sing-box MT and tap **Start** on the MacDroid profile. |
| iPhone's Tailscale turned itself off | Expected: iOS allows one VPN-type app at a time. Stop sing-box MT to get it back. |
| Exit IP is the phone's but slow | That's the phone's own signal and plan. The USB link moves over 2 Gbit/s and isn't the bottleneck. |
| `up` warns the phone is on Wi-Fi | Turn the phone's Wi-Fi off, or you'll be using that Wi-Fi rather than mobile data. |
| An app says offline | Run `./macdroid.sh check` and look at the `primary` line. |
| Tailscale says "Network Down" with Wi-Fi off | Run `./macdroid.sh check` and look at the `Tailscale` line. `ifconfig feth225` should show `198.18.225.1`; if not, toggle MacDroid off and on. |
| Anything stuck | `sudo ./macdroid.sh down`. Even a crash cleans up after itself (see above). |

## Layout

| Path | What |
|---|---|
| `macdroid.sh` | Everything: setup, install, on/off, checks |
| `macdroid/mac.json` | Mac sing-box config: tun, routes, DNS, phone outbound (UDP-over-TCP) |
| `macdroid/phone.json` | Android sing-box config: SOCKS server on phone localhost, DoH resolver |
| `macdroid/iphone.json` | The same, for the sing-box MT app on an iPhone (imported by hand) |
| `macdroid/dnshold.c` | Holds the DNS + primary-service registration for as long as it runs |
| `how-it-works.html` | Visual explainer |

## History

Earlier versions of this repo took two other routes. Both are removed but still in git history:

1. **A userspace RNDIS driver** (`macdroid_tether_extreme.c`). It was a HoRNDIS replacement that made Android USB tethering work on Apple Silicon. It worked, but tethering *is* the hotspot meter.
2. **Every Proxy + `mooch.sh`** (with a tun2socks transparent mode). It used the on-device data path, but `adb forward` only carries TCP, so DNS and all other UDP failed whenever Wi-Fi was off.

## License

MIT
