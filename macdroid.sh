#!/usr/bin/env bash
# macdroid.sh — MacDroid: use the phone's ON-DEVICE data as the Mac's internet, over USB.
#
#   ./macdroid.sh setup          one-time: fetch sing-box, build dnshold, push to phone
#   sudo ./macdroid.sh install   one-time: install as a launchd job + passwordless on/off
#   ./macdroid.sh toggle|start|stop|status    day to day — no sudo (Raycast uses these)
#   ./macdroid.sh check          what's working right now, and why not (no sudo)
#   sudo ./macdroid.sh up        foreground mode for debugging (Ctrl+C = off)
#   sudo ./macdroid.sh down      force teardown from any terminal
#
# How it works (more in README.md and how-it-works.html):
#
#   Mac apps ─▶ utun225 (sing-box tun) ─▶ SOCKS5 + UDP-over-TCP ─▶ adb forward
#            ─▶ USB ─▶ phone: sing-box SOCKS server run by `adb shell` ─▶ cellular
#
# The phone-side server is an ordinary process on the phone opening its own
# sockets — the same data path as any app — so it is not tethering. Unlike the
# old tun2socks/Every Proxy setup, UDP is carried INSIDE the TCP pipe (UoT), so
# DNS, QUIC, NTP, WireGuard and calls all work, not just TCP.
#
# Crash safety — nothing here outlives the processes that own it:
#   • routes belong to utun225; the kernel deletes them when sing-box exits
#   • DNS is a *temporary* SystemConfiguration value held by dnshold; configd
#     deletes it when dnshold exits, even on kill -9
#   • the phone server is a child of an `adb shell` session; it dies with it
#   • Tailscale settings are never touched
# A reboot is never needed to recover. `down` exists only for convenience.

set -u
# As root, run ONLY system binaries: Homebrew and /usr/local/bin are writable by
# the user, and anything in them executed as root would be a privilege hole.
# User-owned tools (adb, tailscale) are run as the user via as_user instead.
if [ "$(id -u)" = 0 ]; then
  export PATH=/usr/bin:/bin:/usr/sbin:/sbin
else
  export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
fi

SB_VERSION=1.14.3
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/bin"
ASSETS="$HERE/macdroid"
SB_MAC="$BIN/sing-box-darwin"
SB_PHONE_LOCAL="$BIN/sing-box-android"
DNSHOLD="$ASSETS/dnshold"
MAC_CFG="$ASSETS/mac.json"
PHONE_CFG="$ASSETS/phone.json"

PHONE_DIR=/data/local/tmp
PHONE_BIN=$PHONE_DIR/macdroid-sb
PHONE_JSON=$PHONE_DIR/macdroid-sb.json
PHONE_PAT="macdroid-s[b] run"   # bracket: never matches the adb wrapper shell itself
PHONE_PORT=1090          # phone.json listen_port (phone localhost only)
LOCAL_PORT=8901          # mac.json phone outbound server_port
TUN_DEV=utun225          # mac.json interface_name
TUN_IP=172.19.0.1
TUN_DNS=172.19.0.2       # hijacked by sing-box (next address after TUN_IP)

STATE=/tmp/macdroid
LOG=/tmp/macdroid.log

# installed (launchd) mode — see cmd_install
LABEL=com.macdroid
INSTALL_DIR=/Library/PrivilegedHelperTools/macdroid
PLIST=/Library/LaunchDaemons/$LABEL.plist
SUDOERS=/etc/sudoers.d/macdroid
JOB_OUT=/tmp/macdroid.out
PROBE_TMO=6
HEALTH_IV=15

ADB_BIN="${MACDROID_ADB:-$(command -v adb 2>/dev/null || echo /opt/homebrew/bin/adb)}"
TS_BIN="$(command -v tailscale 2>/dev/null)"
for _t in /usr/local/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
  [ -z "$TS_BIN" ] && [ -x "$_t" ] && TS_BIN=$_t
done

# When root, run user-owned tools as the real user (MACDROID_USER under launchd,
# SUDO_USER under sudo). adb then also shares the user's adb server instead of
# starting a second, root-owned one on the same port.
as_user() {
  local u="${MACDROID_USER:-${SUDO_USER:-}}"
  if [ "$(id -u)" = 0 ] && [ -n "$u" ]; then
    sudo -u "$u" -H "$@"
  else
    "$@"
  fi
}
adb() { as_user "$ADB_BIN" "$@"; }
pid_alive() { [ -n "${1:-}" ] && ps -p "$1" >/dev/null 2>&1; }   # works across users, unlike kill -0

log()  { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }
say()  { echo "$*"; log "$*"; }
die()  { echo "✗ $*" >&2; exit 1; }

phone_on() { [ "$(adb get-state 2>/dev/null)" = device ]; }

# ---------------------------------------------------------------- probes ----

# exit IP + latency through whatever the Mac's routing currently is
p_transport() {
  local out ip t
  out=$(curl -4 -s --max-time "$PROBE_TMO" -w '\n%{time_total}' https://1.1.1.1/cdn-cgi/trace 2>/dev/null)
  ip=$(printf '%s\n' "$out" | awk -F= '/^ip=/{print $2}')
  t=$(printf '%s\n' "$out" | tail -n 1)
  [ -n "$ip" ] && echo "$ip $(awk -v s="${t:-0}" 'BEGIN{printf "%d", s*1000}')"
}

# the phone's own exit IP, straight through the SOCKS forward (bypasses the tun)
p_phone_ip() {
  curl -4 -s --max-time "$PROBE_TMO" --socks5-hostname "127.0.0.1:$LOCAL_PORT" \
       https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}'
}

# system resolver with a never-seen name, so no cache can fake a pass
p_dns() {
  local name="u$(date +%s)p$$${1:-}.1.1.1.1.sslip.io"
  dscacheutil -q host -a name "$name" 2>/dev/null | grep -q '^ip_address: 1.1.1.1'
}

# real UDP that is NOT DNS (so it can't be answered by the local DNS hijack):
# one NTP query to a literal IPv4 (no DNS, no IPv6 fallback games) — it has to
# cross UDP-over-TCP to the phone and back. Prints the round trip in ms.
p_udp() {
  /usr/bin/python3 -I -c '
import socket,time,sys
s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(5)
t=time.time()
try: s.sendto(b"\x1b"+47*b"\0",("162.159.200.1",123)); s.recvfrom(48)
except Exception: sys.exit(1)
print(int((time.time()-t)*1000))' 2>/dev/null
}

# which interface the phone itself uses for the internet: cell | wifi | none | ?
p_phone_uplink() {
  local dev
  phone_on || { echo "?"; return; }
  dev=$(adb shell ip route get 1.1.1.1 2>/dev/null | tr -d '\r' | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  case "$dev" in
    "")                                 echo none ;;
    wlan*)                              echo wifi ;;
    rmnet*|ccmni*|pdp*|ppp*|qmi*|seth*) echo cell ;;
    *)                                  echo "$dev" ;;
  esac
}

route_if() { route -n get "${1:-1.2.3.4}" 2>/dev/null | awk '/interface:/{print $2}'; }
resolver1() { scutil --dns 2>/dev/null | awk '/^resolver #1/{f=1} f&&/nameserver\[0\]/{print $3; exit}'; }
tailnet_suffix() {
  [ -n "$TS_BIN" ] || return
  as_user "$TS_BIN" status --json 2>/dev/null | /usr/bin/jq -r '.MagicDNSSuffix // empty' 2>/dev/null
}
tailnet_self() {
  [ -n "$TS_BIN" ] || return
  as_user "$TS_BIN" status --json 2>/dev/null | /usr/bin/jq -r '.Self.DNSName // empty' 2>/dev/null | sed 's/\.$//'
}

# ----------------------------------------------------------------- setup ----

cmd_setup() {
  [ "$(id -u)" = 0 ] && die "run setup WITHOUT sudo"
  mkdir -p "$BIN"
  local p
  for p in darwin-arm64:"$SB_MAC" android-arm64:"$SB_PHONE_LOCAL"; do
    local plat=${p%%:*} dest=${p#*:}
    if [ -x "$dest" ]; then echo "✓ have $(basename "$dest")"; continue; fi
    echo "↓ sing-box $SB_VERSION ($plat)"
    local tmp; tmp=$(mktemp -d)
    curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v$SB_VERSION/sing-box-$SB_VERSION-$plat.tar.gz" \
      | tar -xz -C "$tmp" || die "download failed"
    cp "$tmp/sing-box-$SB_VERSION-$plat/sing-box" "$dest" && chmod +x "$dest"
    rm -rf "$tmp"
  done
  [ "$(uname -m)" = arm64 ] || echo "⚠ this Mac is $(uname -m); setup fetched the arm64 build — edit SB_MAC for Intel"

  echo "⚙ building dnshold"
  clang -Wall -Wextra -O2 -o "$DNSHOLD" "$ASSETS/dnshold.c" \
    -framework SystemConfiguration -framework CoreFoundation || die "dnshold build failed"

  "$SB_MAC" check -c "$MAC_CFG"   || die "mac.json failed validation"
  "$SB_MAC" check -c "$PHONE_CFG" || die "phone.json failed validation"
  echo "✓ configs valid"

  phone_on || die "no phone on adb — enable USB debugging, plug in, accept the prompt, re-run setup"
  push_phone && echo "✓ phone ready ($PHONE_BIN)"
  echo
  echo "next:  sudo ./macdroid.sh install    (once; then ./macdroid.sh toggle or Raycast — no sudo)"
}

# copy binary/config to the phone only if they differ
push_phone() {
  local want have
  adb shell "rm -f $PHONE_DIR/mooch-sb $PHONE_DIR/mooch-sb.json" >/dev/null 2>&1   # pre-rename leftovers
  want=$(shasum -a 256 "$SB_PHONE_LOCAL" | awk '{print $1}')
  have=$(adb shell "sha256sum $PHONE_BIN 2>/dev/null" | tr -d '\r' | awk '{print $1}')
  if [ "$want" != "$have" ]; then
    adb push "$SB_PHONE_LOCAL" "$PHONE_BIN" >/dev/null || { echo "✗ adb push failed"; return 1; }
    adb shell chmod 755 "$PHONE_BIN"
  fi
  adb push "$PHONE_CFG" "$PHONE_JSON" >/dev/null || { echo "✗ adb push config failed"; return 1; }
}

# -------------------------------------------------------------- up / down ---

start_phone_server() {
  adb shell "pkill -f '$PHONE_PAT'" >/dev/null 2>&1
  # `exec` so the server IS the shell session: if the cable, adb, or this
  # script goes away, the session closes and the server dies with it.
  adb shell "exec $PHONE_BIN run -c $PHONE_JSON" >> "$STATE/phone.log" 2>&1 &
  echo $! > "$STATE/phone.pid"
  adb forward "tcp:$LOCAL_PORT" "tcp:$PHONE_PORT" >/dev/null
}

wait_phone_socks() {
  local i
  for i in $(seq 1 15); do
    [ -n "$(p_phone_ip)" ] && return 0
    sleep 1
  done
  return 1
}

cleanup() {
  trap - INT TERM HUP EXIT
  local pid
  for f in dnshold mac; do
    pid=$(cat "$STATE/$f.pid" 2>/dev/null)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  # sing-box removes its routes on SIGTERM; give it a moment, then insist
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$SB_MAC run" >/dev/null 2>&1 || break; sleep 0.3
  done
  pkill -9 -f "$SB_MAC run" 2>/dev/null
  pkill -f "$DNSHOLD" 2>/dev/null
  pid=$(cat "$STATE/phone.pid" 2>/dev/null); [ -n "$pid" ] && kill "$pid" 2>/dev/null
  if phone_on; then
    adb shell "pkill -f '$PHONE_PAT'" >/dev/null 2>&1
    adb forward --remove "tcp:$LOCAL_PORT" >/dev/null 2>&1
  fi
  dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null
  rm -rf "$STATE"
  log "teardown complete"
  echo
  echo "✓ MacDroid OFF — Mac is back on its normal network"
}

cmd_up() {
  [ "$(id -u)" = 0 ] || die "needs root:  sudo ./macdroid.sh up"
  [ -x "$SB_MAC" ] && [ -x "$DNSHOLD" ] || die "not set up — run:  ./macdroid.sh setup"
  [ -d "$STATE" ] && pgrep -f "$SB_MAC run" >/dev/null && die "already running (or run: sudo ./macdroid.sh down)"
  phone_on || die "no phone on adb — plug in + enable USB debugging"
  ifconfig "$TUN_DEV" >/dev/null 2>&1 && die "$TUN_DEV already exists — something else owns it (try: sudo ./macdroid.sh down)"

  rm -rf "$STATE"; mkdir -p "$STATE"
  # trap FIRST, before anything is changed, so Ctrl+C at any point is clean
  trap 'cleanup; exit 130' INT TERM HUP
  trap 'cleanup' EXIT
  log "─── up $(date '+%Y-%m-%d') ───"

  # 1) phone side
  push_phone || exit 1
  start_phone_server
  if ! wait_phone_socks; then
    echo "✗ phone server didn't answer. Its output:"; sed 's/^/    /' "$STATE/phone.log"
    exit 1
  fi
  local pip pup
  pip=$(p_phone_ip); pup=$(p_phone_uplink)
  say "✓ phone server up — phone exit IP $pip, phone uplink: $pup"
  [ "$pup" = wifi ] && echo "  ⚠ the PHONE is on Wi-Fi — turn the phone's Wi-Fi off to use its cellular data"

  # 2) Mac tun + routes
  "$SB_MAC" run -c "$MAC_CFG" >> "$STATE/mac.log" 2>&1 &
  echo $! > "$STATE/mac.pid"
  local i
  for i in $(seq 1 30); do
    ifconfig "$TUN_DEV" >/dev/null 2>&1 && break
    kill -0 "$(cat "$STATE/mac.pid")" 2>/dev/null || { echo "✗ sing-box exited:"; sed 's/^/    /' "$STATE/mac.log"; exit 1; }
    sleep 0.2
  done
  ifconfig "$TUN_DEV" >/dev/null 2>&1 || { echo "✗ $TUN_DEV never appeared"; exit 1; }
  say "✓ $TUN_DEV up — internet routes now via the phone (LAN + tailnet stay direct)"

  # 3) DNS — first-choice resolver for as long as dnshold lives
  local suffix; suffix=$(tailnet_suffix)
  "$DNSHOLD" "$TUN_DEV" "$TUN_IP" "$TUN_DNS" $suffix >> "$STATE/dnshold.log" 2>&1 &
  echo $! > "$STATE/dnshold.pid"
  sleep 1
  kill -0 "$(cat "$STATE/dnshold.pid")" 2>/dev/null || { echo "✗ dnshold failed:"; cat "$STATE/dnshold.log"; exit 1; }
  dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null
  say "✓ DNS → $TUN_DNS (answered by sing-box over DoH through the phone)${suffix:+; tailnet names → 100.100.100.100}"

  # 4) verify
  sleep 2
  echo
  verify_line
  : > "$STATE/ready"       # `start` waits for this
  echo
  echo "════════════════════════════════════════════════════════════════"
  echo "  MACDROID ON — the Mac is using the phone's on-device data"
  if [ -n "${MACDROID_USER:-}" ]; then
    echo "  running under launchd — turn off with: ./macdroid.sh stop (or Raycast)"
  else
    echo "  this window IS the switch: Ctrl+C restores everything"
  fi
  echo "  other terminal:  ./macdroid.sh check      log: tail -f $LOG"
  echo "════════════════════════════════════════════════════════════════"

  # 5) hold: supervise, self-heal the phone side on re-plug, report changes
  local tick=0 last="" now phone_pid
  while kill -0 "$(cat "$STATE/mac.pid")" 2>/dev/null && kill -0 "$(cat "$STATE/dnshold.pid")" 2>/dev/null; do
    sleep 1; tick=$((tick+1))
    phone_pid=$(cat "$STATE/phone.pid" 2>/dev/null)
    if ! pid_alive "$phone_pid" && phone_on; then
      say "  $(date '+%H:%M:%S') ↪ phone server gone (re-plugged?) — restarting it"
      push_phone >/dev/null 2>&1; start_phone_server
    fi
    [ $((tick % HEALTH_IV)) = 0 ] || continue
    now=$(health_state)
    if [ "$now" != "$last" ]; then
      say "  $(date '+%H:%M:%S') health: $now"
      last="$now"
    fi
  done
  say "⚠ sing-box or dnshold exited unexpectedly — tearing down"
  sed 's/^/    /' "$STATE/mac.log" | tail -5
}

health_state() {
  local t; t=$(p_transport)
  if [ -z "$t" ]; then echo "DOWN — $(why_down)"; return; fi
  if ! p_dns h; then echo "DNS DOWN (transport ok) — resolver #1 is $(resolver1)"; return; fi
  echo "UP (${t##* }ms)"
}

why_down() {
  phone_on || { echo "phone not on adb (cable? USB debugging?)"; return; }
  pid_alive "$(cat "$STATE/phone.pid" 2>/dev/null)" || { echo "phone server not running"; return; }
  [ -n "$(p_phone_ip)" ] || { echo "phone server running but has no internet (phone uplink: $(p_phone_uplink))"; return; }
  echo "phone is fine but traffic through $TUN_DEV isn't — see $STATE/mac.log"
}

verify_line() {
  local t pip ok=1
  pip=$(p_phone_ip)
  t=$(p_transport)
  if [ -n "$t" ] && [ "${t%% *}" = "$pip" ]; then echo "  ✓ transport   exit ${t%% *} = phone's exit (${t##* }ms)"
  elif [ -n "$t" ]; then echo "  ✗ transport   exit ${t%% *} ≠ phone's ${pip:-?} — NOT going via the phone"; ok=0
  else echo "  ✗ transport   no internet — $(why_down)"; ok=0; fi
  if p_dns v; then echo "  ✓ DNS         names resolve (resolver #1: $(resolver1))"
  else echo "  ✗ DNS         not resolving (resolver #1: $(resolver1))"; ok=0; fi
  local u; u=$(p_udp)
  if [ -n "$u" ]; then echo "  ✓ UDP         NTP round-trip ${u}ms (non-DNS UDP)"
  else echo "  ✗ UDP         NTP to 162.159.200.1 got no reply — UDP-over-TCP not working"; ok=0; fi
  local prim; prim=$(echo 'show State:/Network/Global/IPv4' | scutil 2>/dev/null | awk '/PrimaryInterface/{print $3}')
  if [ "$prim" = "$TUN_DEV" ]; then echo "  ✓ primary     macOS sees $TUN_DEV as the main connection (Chrome etc. won't say offline)"
  elif ifconfig "$TUN_DEV" >/dev/null 2>&1; then echo "  ✗ primary     macOS main connection is '${prim:-none}', not $TUN_DEV — apps may claim offline"; ok=0
  fi
  local self; self=$(tailnet_self)
  if [ -n "$self" ]; then
    if dscacheutil -q host -a name "$self" 2>/dev/null | grep -q ip_address; then echo "  ✓ MagicDNS    $self resolves"
    else echo "  ✗ MagicDNS    $self does not resolve"; ok=0; fi
  fi
  [ "$ok" = 1 ]
}

cmd_down() {
  [ "$(id -u)" = 0 ] || die "needs root:  sudo ./macdroid.sh down"
  cleanup
}


# --------------------------------------------- install / day-to-day (no sudo) ---
#
# install puts a ROOT-OWNED copy of everything in $INSTALL_DIR, registers it as
# a launchd job (not started at boot), and adds a sudoers rule that allows
# exactly two commands without a password: start and stop that one job. Since
# every file the job runs is root-owned and root mode only uses system
# binaries, the rule can't be used to run anything else as root.
# Re-run install after changing anything in the repo.

cmd_install() {
  [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] || die "run:  sudo ./macdroid.sh install"
  local f
  for f in "$SB_MAC" "$SB_PHONE_LOCAL" "$DNSHOLD"; do
    [ -x "$f" ] || die "missing $f — run ./macdroid.sh setup first (without sudo)"
  done
  [ "$(stat -f %Su "$(dirname "$INSTALL_DIR")")" = root ] || die "$(dirname "$INSTALL_DIR") isn't root-owned; refusing"

  # if it's on right now (old or current install), bring it back up afterwards
  local was_on=0; tun_up && was_on=1
  [ "$was_on" = 1 ] && echo "↪ MacDroid is on — it will drop for ~15s and come back after the install"

  # migrate from the pre-rename install ("uplink", com.mooch.uplink)
  if [ -e /Library/LaunchDaemons/com.mooch.uplink.plist ] || [ -e /etc/sudoers.d/mooch-uplink ]; then
    echo "↪ removing the old 'uplink' install"
    launchctl kill TERM system/com.mooch.uplink >/dev/null 2>&1
    launchctl bootout system/com.mooch.uplink >/dev/null 2>&1
    rm -f /Library/LaunchDaemons/com.mooch.uplink.plist /etc/sudoers.d/mooch-uplink
    rm -rf /Library/PrivilegedHelperTools/mooch-uplink
  fi

  launchctl kill TERM "system/$LABEL" >/dev/null 2>&1
  local i
  for i in $(seq 1 30); do tun_up || break; sleep 0.5; done
  launchctl bootout "system/$LABEL" >/dev/null 2>&1
  rm -rf "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/macdroid"
  install -m 755 "$HERE/macdroid.sh" "$INSTALL_DIR/macdroid.sh"
  install -m 755 "$SB_MAC" "$SB_PHONE_LOCAL" "$INSTALL_DIR/bin/"
  install -m 755 "$DNSHOLD" "$INSTALL_DIR/macdroid/"
  install -m 644 "$MAC_CFG" "$PHONE_CFG" "$INSTALL_DIR/macdroid/"
  chown -R root:wheel "$INSTALL_DIR"; chmod 755 "$INSTALL_DIR"

  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$INSTALL_DIR/macdroid.sh</string><string>up</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>MACDROID_USER</key><string>$SUDO_USER</string>
    <key>MACDROID_ADB</key><string>$ADB_BIN</string>
  </dict>
  <key>RunAtLoad</key><false/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>$JOB_OUT</string>
  <key>StandardErrorPath</key><string>$JOB_OUT</string>
</dict>
</plist>
EOF
  chown root:wheel "$PLIST"; chmod 644 "$PLIST"
  plutil -lint "$PLIST" >/dev/null || die "generated plist is invalid"

  local tmp; tmp=$(mktemp)
  printf '%s ALL=(root) NOPASSWD: /bin/launchctl kickstart system/%s, /bin/launchctl kill TERM system/%s\n' \
    "$SUDO_USER" "$LABEL" "$LABEL" > "$tmp"
  visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die "sudoers rule failed validation"; }
  install -m 440 -o root -g wheel "$tmp" "$SUDOERS"; rm -f "$tmp"

  launchctl bootstrap system "$PLIST" || die "launchctl bootstrap failed"
  echo "✓ installed to $INSTALL_DIR"
  echo "✓ launchd job $LABEL (starts only when you turn it on)"
  echo "✓ passwordless on/off for $SUDO_USER (only: start/stop this job)"
  if [ "$was_on" = 1 ]; then
    echo "↪ turning MacDroid back on…"
    launchctl kickstart "system/$LABEL"
    for i in $(seq 1 60); do [ -f "$STATE/ready" ] && break; sleep 0.5; done
    echo "  $(status_line)"
  fi
  echo
  echo "now:  ./macdroid.sh toggle     — or the Raycast 'MacDroid' commands"
}

cmd_uninstall() {
  [ "$(id -u)" = 0 ] || die "run:  sudo ./macdroid.sh uninstall"
  launchctl kill TERM "system/$LABEL" >/dev/null 2>&1; sleep 2
  launchctl bootout "system/$LABEL" >/dev/null 2>&1
  rm -f "$PLIST" "$SUDOERS"; rm -rf "$INSTALL_DIR"
  echo "✓ uninstalled (launchd job, sudoers rule and $INSTALL_DIR removed)"
}

job_running() { pgrep -f "$INSTALL_DIR/macdroid.sh up" >/dev/null 2>&1; }
tun_up()      { ifconfig "$TUN_DEV" >/dev/null 2>&1; }

# one line, fast — what Raycast shows
status_line() {
  if tun_up; then
    local t; t=$(p_transport)
    if [ -n "$t" ]; then echo "📱 MacDroid ON · ${t##* }ms · exit ${t%% *}"
    else echo "⚠️ MacDroid ON but no internet — $(why_down)"; fi
  elif job_running; then
    echo "⏳ MacDroid starting…"
  else
    echo "⚪ MacDroid OFF"
  fi
}

cmd_start() {
  [ -x "$INSTALL_DIR/macdroid.sh" ] || die "not installed — run:  sudo ./macdroid.sh install"
  if tun_up; then status_line; return 0; fi
  phone_on || { echo "📵 Phone not on adb — plug in, USB debugging on"; return 1; }
  sudo -n /bin/launchctl kickstart "system/$LABEL" 2>/dev/null \
    || { echo "✗ couldn't start the job — re-run:  sudo ./macdroid.sh install"; return 1; }
  local i
  for i in $(seq 1 60); do
    [ -f "$STATE/ready" ] && { status_line; return 0; }
    [ "$i" -gt 6 ] && ! job_running && break
    sleep 0.5
  done
  echo "✗ MacDroid didn't come up: $(grep -E '✗|⚠' "$JOB_OUT" 2>/dev/null | tail -n 1)"
  return 1
}

cmd_stop() {
  if ! tun_up && ! job_running; then echo "⚪ MacDroid OFF"; return 0; fi
  sudo -n /bin/launchctl kill TERM "system/$LABEL" 2>/dev/null \
    || { echo "✗ couldn't stop it (started by hand?) — run:  sudo ./macdroid.sh down"; return 1; }
  local i
  for i in $(seq 1 30); do
    tun_up || { echo "⚪ MacDroid OFF — back on your normal network"; return 0; }
    sleep 0.5
  done
  echo "✗ still up — run:  sudo ./macdroid.sh down"; return 1
}

cmd_toggle() { if tun_up || job_running; then cmd_stop; else cmd_start; fi; }

# ----------------------------------------------------------------- check ----

cmd_check() {
  local running=no
  ifconfig "$TUN_DEV" >/dev/null 2>&1 && running=yes
  echo "── state ──"
  echo "  MacDroid on    : $running   (internet route via $(route_if 1.2.3.4); LAN via $(route_if 192.168.1.1))"
  echo "  resolver #1    : $(resolver1)"
  if phone_on; then
    echo "  phone          : on adb, uplink $(p_phone_uplink), server $([ -n "$(p_phone_ip)" ] && echo answering || echo 'not answering')"
  else
    echo "  phone          : NOT on adb"
  fi
  echo "── probes ──"
  verify_line && { echo; echo "  ✅ all good"; } || { echo; echo "  ❌ something failed (above)"; }
  echo
  echo "  note: ping/ICMP isn't carried — use curl/this check, not ping"
}

case "${1:-}" in
  setup)     cmd_setup ;;
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  start|on)  cmd_start ;;
  stop|off)  cmd_stop ;;
  toggle)    cmd_toggle ;;
  status)    status_line ;;
  up)        cmd_up ;;
  down|panic) cmd_down ;;
  check)     cmd_check ;;
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
