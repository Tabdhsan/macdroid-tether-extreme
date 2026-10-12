#!/usr/bin/env bash
# mooch.sh — route this Mac through the phone's on-device 5G via an on-phone
# proxy (Every Proxy) piped over the USB cable with adb.
#
# This is NOT tethering — the phone's proxy app fetches on-device, so the
# carrier's hotspot/tethering speed cap never applies. The Mac "mooches" the
# phone's own data path over the cable.
#
#   source ./mooch.sh on       turn everything ON  (adb pipe + system SOCKS + shell)
#   source ./mooch.sh off      turn everything OFF (full revert)
#   source ./mooch.sh status   show current state
#
# It must be SOURCED (not executed) so it can set/clear the proxy env vars in
# YOUR shell for Claude Code. The system-proxy parts work either way.
#
# What "on" changes, and what "off" reverts — nothing persists past `off`:
#   • adb forward tcp:8899  (Mac localhost:8899 -> phone:8080  HTTP proxy)
#   • adb forward tcp:8900  (Mac localhost:8900 -> phone:1080  SOCKS5 proxy)
#   • macOS system SOCKS proxy on your active service -> 127.0.0.1:8900
#   • HTTP(S)_PROXY / ALL_PROXY / NO_PROXY exported in this shell
# The system SOCKS proxy covers all apps (Telegram, Slack, etc.).
# The shell env vars cover CLI tools (curl, git, Claude Code).
# Tailscale (100.64.0.0/10, *.ts.net) and localhost are always bypassed.

_TTHR_HOST=127.0.0.1
_TTHR_PORT=8899              # Mac-side local port for HTTP proxy
_TTHR_PHONE_PORT=8080        # port Every Proxy's HTTP proxy listens on
_TTHR_SOCKS_PORT=8900        # Mac-side local port for SOCKS5 proxy
_TTHR_PHONE_SOCKS_PORT=1080  # port Every Proxy's SOCKS5 proxy listens on
_TTHR_NOPROXY="localhost,127.0.0.1,::1,100.64.0.0/10,*.ts.net"

# --- detect sourced vs executed (env vars only "take" when sourced) ----------
_tthr_sourced() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    [[ "$ZSH_EVAL_CONTEXT" == *file* ]]
  else
    [ "${BASH_SOURCE[0]}" != "$0" ]
  fi
}

# --- map the default-route interface to its macOS network service name -------
_tthr_service() {
  local dev
  dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  networksetup -listnetworkserviceorder 2>/dev/null | awk -v dev="$dev" '
    /^\([0-9]+\)/ { name=substr($0, index($0,")")+2) }
    index($0, "Device: " dev ")") { print name; exit }
  '
}

_tthr_on() {
  # 1) phone present?
  if [ "$(adb get-state 2>/dev/null)" != "device" ]; then
    echo "✗ no phone on adb — plug in USB + enable USB debugging"; return 1
  fi
  # 1b) local ports free?
  local holder
  for _p in $_TTHR_PORT $_TTHR_SOCKS_PORT; do
    holder=$(lsof -nP -iTCP:$_p -sTCP:LISTEN 2>/dev/null | awk 'NR>1 && $1!="adb"{print $1; exit}')
    if [ -n "$holder" ]; then
      echo "✗ local port $_p is already in use by '$holder' — the USB pipe can't bind cleanly."
      return 1
    fi
  done
  # 2) USB pipes — HTTP + SOCKS5
  adb forward tcp:$_TTHR_PORT tcp:$_TTHR_PHONE_PORT >/dev/null || { echo "✗ adb forward (HTTP) failed"; return 1; }
  adb forward tcp:$_TTHR_SOCKS_PORT tcp:$_TTHR_PHONE_SOCKS_PORT >/dev/null || {
    echo "✗ adb forward (SOCKS5) failed"
    adb forward --remove tcp:$_TTHR_PORT 2>/dev/null; return 1
  }
  # 3) probe each proxy — at least one must answer
  local _http_live=0 _socks_live=0
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --proxy http://$_TTHR_HOST:$_TTHR_PORT \
         --connect-timeout 6 --max-time 10 "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null)
  if [ "$code" = "200" ]; then
    _http_live=1
  else
    echo "⚠ HTTP proxy not answering (got '$code') — skipping."
    adb forward --remove tcp:$_TTHR_PORT 2>/dev/null
  fi
  local socks_ok
  socks_ok=$(curl -s -o /dev/null -w '%{http_code}' --proxy socks5h://$_TTHR_HOST:$_TTHR_SOCKS_PORT \
             --connect-timeout 6 --max-time 10 "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null)
  if [ "$socks_ok" = "200" ]; then
    _socks_live=1
  else
    echo "⚠ SOCKS5 proxy not answering (got '$socks_ok') — skipping."
    adb forward --remove tcp:$_TTHR_SOCKS_PORT 2>/dev/null
  fi
  if [ "$_http_live" = "0" ] && [ "$_socks_live" = "0" ]; then
    echo "✗ neither proxy is answering on the phone."
    echo "  Open Every Proxy and enable at least one: HTTP (port $_TTHR_PHONE_PORT) or SOCKS5 (port $_TTHR_PHONE_SOCKS_PORT)."
    adb forward --remove tcp:$_TTHR_PORT 2>/dev/null
    adb forward --remove tcp:$_TTHR_SOCKS_PORT 2>/dev/null
    return 1
  fi
  # 4) system SOCKS proxy — makes all apps (Telegram, Slack, etc.) use the phone
  local svc; svc=$(_tthr_service); [ -z "$svc" ] && svc="Wi-Fi"
  if [ "$_socks_live" = "1" ]; then
    networksetup -setsocksfirewallproxy "$svc" "$_TTHR_HOST" "$_TTHR_SOCKS_PORT" 2>/dev/null
    networksetup -setproxybypassdomains "$svc" localhost 127.0.0.1 "*.ts.net" "100.64.0.0/10" 2>/dev/null
    networksetup -setsocksfirewallproxystate "$svc" on 2>/dev/null
  fi
  # 5) shell / Claude Code
  if _tthr_sourced; then
    if [ "$_http_live" = "1" ]; then
      export HTTP_PROXY="http://$_TTHR_HOST:$_TTHR_PORT" HTTPS_PROXY="http://$_TTHR_HOST:$_TTHR_PORT"
      export http_proxy="$HTTP_PROXY" https_proxy="$HTTPS_PROXY"
    fi
    if [ "$_socks_live" = "1" ]; then
      export ALL_PROXY="socks5://$_TTHR_HOST:$_TTHR_SOCKS_PORT" all_proxy="$ALL_PROXY"
    elif [ "$_http_live" = "1" ]; then
      export ALL_PROXY="http://$_TTHR_HOST:$_TTHR_PORT" all_proxy="$ALL_PROXY"
    fi
    export NO_PROXY="$_TTHR_NOPROXY" no_proxy="$_TTHR_NOPROXY"
  fi
  echo "✓ mooch ON  (service: $svc)"
  [ "$_socks_live" = "1" ] && echo "  SOCKS5 system proxy: $_TTHR_HOST:$_TTHR_SOCKS_PORT  (Telegram, Slack, all apps)"
  [ "$_http_live" = "1" ]  && echo "  HTTP  shell proxy:   $_TTHR_HOST:$_TTHR_PORT  (curl, git, Claude Code)"
  [ "$_socks_live" = "0" ] && echo "  ⚠ SOCKS5 off — only proxy-aware apps (browser, CLI) will use the phone"
  _tthr_sourced || echo "  note: run with 'source' to also set HTTPS_PROXY for Claude Code in this shell"
}

_tthr_off() {
  local svc; svc=$(_tthr_service); [ -z "$svc" ] && svc="Wi-Fi"
  networksetup -setsocksfirewallproxystate "$svc" off 2>/dev/null
  adb forward --remove tcp:$_TTHR_PORT 2>/dev/null
  adb forward --remove tcp:$_TTHR_SOCKS_PORT 2>/dev/null
  if _tthr_sourced; then
    unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy NO_PROXY no_proxy
  fi
  echo "✓ mooch OFF (service: $svc)  — back to normal Wi-Fi, all proxy settings cleared"
}

_tthr_status() {
  local svc; svc=$(_tthr_service); [ -z "$svc" ] && svc="Wi-Fi"
  echo "network service : $svc"
  echo -n "system SOCKS    : "; networksetup -getsocksfirewallproxy "$svc" 2>/dev/null | awk 'NR<=3{printf "%s ",$0} END{print ""}'
  echo    "shell HTTPS_PROXY: ${HTTPS_PROXY:-<unset>}"
  echo    "shell ALL_PROXY  : ${ALL_PROXY:-<unset>}"
  echo -n "adb forward     : "; adb forward --list 2>/dev/null | grep -E ":($_TTHR_PORT|$_TTHR_SOCKS_PORT) " || echo "<none>"
  echo -n "HTTP proxy      : "
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' --proxy http://$_TTHR_HOST:$_TTHR_PORT --max-time 8 "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null)
  [ "$code" = "200" ] && echo "up" || echo "down"
  echo -n "SOCKS5 proxy    : "
  local scode; scode=$(curl -s -o /dev/null -w '%{http_code}' --proxy socks5h://$_TTHR_HOST:$_TTHR_SOCKS_PORT --max-time 8 "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null)
  [ "$scode" = "200" ] && echo "up" || echo "down"
}

# --- launch a Chrome that proxies through the phone, Wi-Fi or not -------------
# Uses a dedicated profile + the --proxy-server flag so it works even with
# Wi-Fi off (unlike the macOS system proxy, which dies with the Wi-Fi service).
_tthr_browser() {
  local url="${2:-https://1.1.1.1/cdn-cgi/trace}"
  open -na "Google Chrome" --args \
    --proxy-server="socks5://$_TTHR_HOST:$_TTHR_SOCKS_PORT" \
    --user-data-dir="$HOME/.mooch-chrome" \
    "$url" 2>/dev/null \
    && echo "✓ opened a proxied Chrome window (via $_TTHR_HOST:$_TTHR_PORT) — survives Wi-Fi off" \
    || echo "✗ couldn't launch Chrome"
}

# =============================================================================
# TRANSPARENT / UPLINK MODE  —  tun2socks + default route
# =============================================================================
# The proxy modes above configure apps one at a time. This instead makes the
# phone the Mac's *uplink*: it stands up a utun interface, points the default
# route at it, and tun2socks forwards everything over the SOCKS pipe to the
# phone's on-device data. Same model as macdroid-tether-extreme, but the far
# end is the phone's proxy app rather than RNDIS. No app is configured; every
# app, every terminal, Chrome included, just works.
#
#   sudo ./mooch.sh transparent   bring it up (foreground; Ctrl+C = clean stop)
#   sudo ./mooch.sh panic         force-remove everything, from any terminal
#
# Safety: teardown is wired to Ctrl+C / exit and is idempotent; state lives in
# /tmp/mooch so `panic` works even from another window; and a REBOOT always
# restores stock networking no matter what.

_TTHR_TUN_IP=198.18.0.1       # arbitrary private addr for the tun endpoint
_TTHR_TUN_MTU=1500
_TTHR_STATE=/tmp/mooch
_TTHR_LOG=/tmp/mooch.log      # persistent event log — NOT wiped on cleanup
_TTHR_DNS="1.1.1.1 1.0.0.1"   # resolvers reachable THROUGH the tunnel (literal IPs)
_TTHR_SCUTIL_SVC=mooch        # synthetic SystemConfiguration service id for our DNS

# timestamped event log, so after the fact you can see exactly what mooch did
# and when — route steals, DNS changes, teardown. Survives cleanup (reboot-safe
# to delete). Tail it live in another terminal:  tail -f /tmp/mooch.log
_tthr_log() { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*" >> "$_TTHR_LOG" 2>/dev/null; }

# locate the tun2socks binary sitting next to this script (override: TUN2SOCKS_BIN)
_tthr_t2s_bin() {
  local d=""
  [ -n "${BASH_SOURCE:-}" ] && d=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
  [ -z "$d" ] && d=$(pwd)
  echo "${TUN2SOCKS_BIN:-$d/tun2socks}"
}

# --- DNS through the tunnel (Wi-Fi-independent) ------------------------------
# The old approach set DNS on the *Wi-Fi service* (networksetup), which macOS
# tears down the instant Wi-Fi goes off — so DNS died in the one case that
# matters (Wi-Fi off, phone-only). Two fixes, together:
#   1) Register our resolver as our OWN SystemConfiguration service bound to the
#      tunnel interface (like macdroid_tether does). Independent of Wi-Fi; lives
#      only in the volatile State store, so a reboot always clears it.
#   2) If Tailscale is running DNS (it owns resolver #1 and forwards public
#      lookups to the LAN gateway, which is unreachable with Wi-Fi off), hand
#      DNS back to the system for the session with `--accept-dns=false`. The VPN
#      stays up; only DNS management is paused. Restored on teardown.
_tthr_dns_register() {
  local dev="$1"
  # 1) step Tailscale's DNS aside if it's the one in charge
  if command -v tailscale >/dev/null 2>&1 && scutil --dns 2>/dev/null | grep -q '100\.100\.100\.100'; then
    if tailscale set --accept-dns=false 2>/dev/null; then
      : > "$_TTHR_STATE/ts_dns_paused" 2>/dev/null
      _tthr_log "dns: paused Tailscale DNS management (accept-dns=false)"
      echo "  ↪ paused Tailscale DNS for the session (VPN stays up)"
    fi
  fi
  # 2) register our resolver as a full SC service AND force it primary. The
  #    earlier version only added a DNS key, which macOS treated as a low-rank
  #    supplemental resolver — so resolver #1 stayed the Wi-Fi gateway
  #    (192.168.1.1), unreachable once Wi-Fi went off. Now we give the service a
  #    real IPv4 dict WITH a Router (so IPMonitor ranks it as having a default
  #    route) and explicitly pin it as PrimaryService — so 1.1.1.1 becomes
  #    resolver #1 even with Wi-Fi off. We save the old primary to restore later.
  local origp
  origp=$(echo 'show State:/Network/Global/IPv4' | scutil 2>/dev/null | awk '/PrimaryService/{print $3}')
  echo "$origp" > "$_TTHR_STATE/orig_primary"
  scutil >/dev/null 2>&1 <<EOF
d.init
d.add ServerAddresses * $_TTHR_DNS
set State:/Network/Service/$_TTHR_SCUTIL_SVC/DNS
d.init
d.add Addresses * $_TTHR_TUN_IP
d.add SubnetMasks * 255.255.255.255
d.add InterfaceName $dev
d.add Router $_TTHR_TUN_IP
set State:/Network/Service/$_TTHR_SCUTIL_SVC/IPv4
get State:/Network/Global/IPv4
d.add PrimaryService $_TTHR_SCUTIL_SVC
d.add PrimaryInterface $dev
set State:/Network/Global/IPv4
quit
EOF
  dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null
  _tthr_log "dns: registered $_TTHR_DNS as PRIMARY service on $dev (prev primary=${origp:-none})"
}

# lightweight re-assert — configd may recompute the primary service on a network
# change (e.g. Wi-Fi toggled) and steal resolver #1 back. Cheap to re-pin.
_tthr_dns_reassert() {
  local dev="$1"
  scutil >/dev/null 2>&1 <<EOF
get State:/Network/Global/IPv4
d.add PrimaryService $_TTHR_SCUTIL_SVC
d.add PrimaryInterface $dev
set State:/Network/Global/IPv4
quit
EOF
  dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null
}

_tthr_dns_unregister() {
  local origp; origp=$(cat "$_TTHR_STATE/orig_primary" 2>/dev/null)
  scutil >/dev/null 2>&1 <<EOF
remove State:/Network/Service/$_TTHR_SCUTIL_SVC/IPv4
remove State:/Network/Service/$_TTHR_SCUTIL_SVC/DNS
quit
EOF
  # hand the primary service back to what it was (configd also self-heals on the
  # next network change, but restoring explicitly avoids a gap)
  if [ -n "$origp" ]; then
    scutil >/dev/null 2>&1 <<EOF
get State:/Network/Global/IPv4
d.add PrimaryService $origp
set State:/Network/Global/IPv4
quit
EOF
  fi
  if [ -f "$_TTHR_STATE/ts_dns_paused" ] && command -v tailscale >/dev/null 2>&1; then
    # restore + VERIFY + retry — a single fire-and-forget set has been seen to
    # not stick during teardown, which leaves Tailscale DNS paused (the footgun)
    local n ok=0
    for n in 1 2 3; do
      tailscale set --accept-dns=true 2>/dev/null
      case "$(tailscale debug prefs 2>/dev/null | grep -i CorpDNS)" in *true*) ok=1; break ;; esac
      sleep 1
    done
    rm -f "$_TTHR_STATE/ts_dns_paused" 2>/dev/null
    if [ "$ok" = 1 ]; then _tthr_log "dns: restored Tailscale DNS (accept-dns=true, verified)"
    else _tthr_log "dns: ⚠ FAILED to restore Tailscale DNS after 3 tries — run: mooch.sh dns-reset"; fi
  fi
  dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null
  _tthr_log "dns: unregistered scutil service '$_TTHR_SCUTIL_SVC'"
}

# idempotent, error-tolerant — safe to run any number of times, in any order
_tthr_transparent_cleanup() {
  local dev gw
  if [ -f "$_TTHR_STATE/t2s.pid" ]; then
    kill "$(cat "$_TTHR_STATE/t2s.pid" 2>/dev/null)" 2>/dev/null
  fi
  pkill -f "$(_tthr_t2s_bin)" 2>/dev/null
  gw=$(cat "$_TTHR_STATE/saved_gw" 2>/dev/null)
  route -n delete default >/dev/null 2>&1
  [ -n "$gw" ] && route -n add default "$gw" >/dev/null 2>&1
  dev=$(cat "$_TTHR_STATE/tun_dev" 2>/dev/null)
  [ -n "$dev" ] && ifconfig "$dev" down 2>/dev/null
  _tthr_dns_unregister
  _tthr_log "cleanup: done — default route restored to gw=${gw:-none}"
  rm -rf "$_TTHR_STATE" 2>/dev/null
}

_tthr_transparent() {
  if [ "$(id -u)" != "0" ]; then
    echo "✗ transparent mode needs root — run:  sudo ./mooch.sh transparent"; return 1
  fi
  local bin; bin=$(_tthr_t2s_bin)
  [ -x "$bin" ] || { echo "✗ tun2socks not found/executable at: $bin"; return 1; }
  if [ "$(adb get-state 2>/dev/null)" != "device" ]; then
    echo "✗ no phone on adb — plug in USB + enable USB debugging"; return 1
  fi

  mkdir -p "$_TTHR_STATE"

  # 1) SOCKS pipe over USB, and confirm the phone is actually answering
  adb forward tcp:$_TTHR_SOCKS_PORT tcp:$_TTHR_PHONE_SOCKS_PORT >/dev/null || {
    echo "✗ adb forward (SOCKS5) failed"; _tthr_transparent_cleanup; return 1; }
  local scode
  scode=$(curl -s -o /dev/null -w '%{http_code}' --proxy socks5h://$_TTHR_HOST:$_TTHR_SOCKS_PORT \
          --connect-timeout 6 --max-time 10 "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null)
  if [ "$scode" != "200" ]; then
    echo "✗ phone SOCKS5 not answering (got '$scode') — open Every Proxy and enable SOCKS5 (port $_TTHR_PHONE_SOCKS_PORT)"
    _tthr_transparent_cleanup; return 1
  fi
  echo "✓ phone SOCKS5 reachable over USB"
  # baseline for the log: what the phone itself is on, and its exit IP, so a
  # later "exit ≠ phone" or "phone on wifi" verdict has something to compare to
  local pip pup
  pip=$(_tthr_p_phone_ip); pup=$(_tthr_p_phone_uplink)
  echo "  phone uplink: $pup   phone exit IP: ${pip:-unknown}"
  _tthr_log "─── transparent session $(date '+%Y-%m-%d') ─── phone uplink=$pup exit=${pip:-unknown}"
  [ "$pup" = wifi ] && echo "  ⚠ the phone is on Wi-Fi — you'll exit via the phone's Wi-Fi, not 5G, until you turn the phone's Wi-Fi off"

  # 2) remember the exact default route so we can put it back
  local gw iface
  gw=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
  iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  echo "$gw"    > "$_TTHR_STATE/saved_gw"
  echo "$iface" > "$_TTHR_STATE/saved_iface"
  echo "  saved current default route: gw=${gw:-none} iface=${iface:-none}"
  _tthr_log "transparent: starting (pid $$) — saved default gw=${gw:-none} iface=${iface:-none}"

  # 3) start tun2socks and detect whichever utun it created
  ifconfig -l | tr ' ' '\n' | grep '^utun' | sort > "$_TTHR_STATE/utun_before"
  echo "  starting tun2socks..."
  "$bin" --device utun123 --proxy "socks5://$_TTHR_HOST:$_TTHR_SOCKS_PORT" --loglevel warn \
      > "$_TTHR_STATE/t2s.log" 2>&1 &
  echo $! > "$_TTHR_STATE/t2s.pid"

  local dev="" i
  for i in $(seq 1 25); do
    dev=$(ifconfig -l | tr ' ' '\n' | grep '^utun' | sort | grep -vxF -f "$_TTHR_STATE/utun_before" | head -1)
    [ -n "$dev" ] && break
    kill -0 "$(cat "$_TTHR_STATE/t2s.pid" 2>/dev/null)" 2>/dev/null || {
      echo "✗ tun2socks exited early:"; cat "$_TTHR_STATE/t2s.log"; _tthr_transparent_cleanup; return 1; }
    sleep 0.2
  done
  [ -z "$dev" ] && { echo "✗ tun2socks didn't create a utun:"; cat "$_TTHR_STATE/t2s.log"; _tthr_transparent_cleanup; return 1; }
  echo "$dev" > "$_TTHR_STATE/tun_dev"
  echo "✓ tun2socks up on $dev"

  # 4) configure the tun and point the default route at it
  ifconfig "$dev" inet "$_TTHR_TUN_IP" "$_TTHR_TUN_IP" up 2>/dev/null
  ifconfig "$dev" mtu "$_TTHR_TUN_MTU" 2>/dev/null
  route -n delete default >/dev/null 2>&1
  route -n add default -interface "$dev" >/dev/null 2>&1
  echo "✓ default route now via $dev"
  _tthr_log "route: default -> $dev"

  # DNS: register a tunnel-reachable resolver as our own SC service (Wi-Fi-
  # independent) and step Tailscale aside if needed. THIS is the piece that was
  # broken before — see _tthr_dns_register.
  _tthr_dns_register "$dev"
  echo "✓ DNS -> $_TTHR_DNS (bound to $dev, survives Wi-Fi off)"

  # 5) cleanup on ANY exit (Ctrl+C, terminal close, crash). Self-clear the trap
  #    first so it fires exactly ONCE (INT then EXIT was double-running cleanup).
  trap 'trap - INT TERM EXIT; _tthr_transparent_cleanup; echo; echo "✓ transparent mode OFF — routing restored"; exit 0' INT TERM EXIT

  echo
  echo "════════════════════════════════════════════════════════════════"
  echo "  TRANSPARENT MODE ON — all traffic now flows through the phone"
  echo "  ---------------------------------------------------------------"
  echo "  verify (new terminal):  ./mooch.sh check                 (transport + DNS + which exit, with why)"
  echo "                          ./mooch.sh watch                 (live timeline as you toggle things)"
  echo "                          tail -f $_TTHR_LOG                (everything this window does)"
  echo "  health is probed every ${_TTHR_HEALTH_IV}s below; UP/DOWN transitions print here + go to the log"
  echo "  this window IS the switch — press Ctrl+C to stop and restore"
  echo "  panic from anywhere  :  sudo ./mooch.sh panic"
  echo "════════════════════════════════════════════════════════════════"

  # 6) hold, and reassert route + primary-DNS if macOS steals them back (a Wi-Fi
  #    toggle makes configd recompute both). Keeps the phone primary so you can
  #    turn Wi-Fi off/on freely without losing routing or name resolution.
  #    Every _TTHR_HEALTH_IV seconds also: restore the adb forward if the cable
  #    was re-plugged (forwards vanish with the device), and probe transport+DNS
  #    through the tunnel so a dead link is reported with a reason instead of
  #    silently blackholing the Mac.
  local pid cur res wdev tick=0 health="" now t d msg lastwhy=0
  pid=$(cat "$_TTHR_STATE/t2s.pid")
  wdev=$(_tthr_wifi_dev)
  while kill -0 "$pid" 2>/dev/null; do
    cur=$(_tthr_route_if)
    if [ "$cur" != "$dev" ]; then
      _tthr_log "route: default was stolen by '${cur:-none}' (Wi-Fi toggled?) — reasserting $dev"
      route -n delete default >/dev/null 2>&1
      route -n add default -interface "$dev" >/dev/null 2>&1
    fi
    # Only force our DNS primary when Wi-Fi is DOWN — that's the only time the
    # Wi-Fi resolver (192.168.1.1) is unreachable. With Wi-Fi up it resolves
    # fine, so leave it alone rather than thrash against configd every second.
    res=$(_tthr_resolver1)
    case "$res" in
      1.1.1.1|1.0.0.1) : ;;   # our tunnel DNS is primary — good
      *) if [ -z "$(ipconfig getifaddr "$wdev" 2>/dev/null)" ]; then
           _tthr_log "dns: resolver #1='${res:-none}' while Wi-Fi is down — re-pinning $_TTHR_DNS primary"
           _tthr_dns_reassert "$dev"
         fi ;;
    esac

    tick=$((tick+1))
    if [ $((tick % _TTHR_HEALTH_IV)) = 0 ]; then
      # forwards vanish when the cable is re-plugged; tun2socks dials 127.0.0.1
      # per connection, so putting the forward back is all it takes to recover
      if [ "$(adb get-state 2>/dev/null)" = device ] && ! _tthr_fwd_up; then
        if _tthr_fwd_ensure; then
          _tthr_log "health: adb forward tcp:$_TTHR_SOCKS_PORT was gone — restored (cable re-plugged?)"
          echo "  $(date '+%H:%M:%S') ↪ adb forward restored (cable re-plugged?)"
        fi
      fi
      t=$(_tthr_p_transport); d=$(_tthr_p_dns h)
      if   [ -n "$t" ] && [ "${d%% *}" = ok ]; then now=UP
      elif [ -n "$t" ];                         then now="DNS DOWN"
      else                                           now=DOWN; fi
      if [ "$now" != "$health" ]; then
        case "$now" in
          UP)         msg="health: UP — $(_tthr_exit_tag "${t%% *}") (${t##* }ms), dns ${d#ok }ms" ;;
          "DNS DOWN") msg="health: transport OK (exit ${t%% *}) but DNS FAILING (curl rc ${d#fail }) — $(_tthr_diagnose_dns)" ;;
          DOWN)       msg="health: DOWN — $(_tthr_diagnose)" ;;
        esac
        _tthr_log "$msg"; echo "  $(date '+%H:%M:%S') $msg"
        health="$now"; lastwhy=$tick
      elif [ "$now" != UP ] && [ $((tick - lastwhy)) -ge 60 ]; then
        # still broken a minute later: re-diagnose, the reason may have moved
        if [ "$now" = DOWN ]; then msg="health: still DOWN — $(_tthr_diagnose)"; else msg="health: still DNS DOWN — $(_tthr_diagnose_dns)"; fi
        _tthr_log "$msg"; echo "  $(date '+%H:%M:%S') $msg"
        lastwhy=$tick
      fi
    fi
    sleep 1
  done
  _tthr_log "transparent: tun2socks exited on its own"
  echo "⚠ tun2socks exited on its own — cleaning up"
}

_tthr_panic() {
  if [ "$(id -u)" != "0" ]; then echo "✗ run:  sudo ./mooch.sh panic"; return 1; fi
  echo "panic: tearing everything down..."
  _tthr_log "panic: invoked"
  _tthr_transparent_cleanup
  _tthr_dnsreset_body     # belt-and-suspenders: also un-stick DNS + Tailscale
  networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | while IFS= read -r svc; do
    networksetup -setsocksfirewallproxystate "$svc" off 2>/dev/null
  done
  adb forward --remove-all 2>/dev/null
  echo "✓ done — if anything still looks off, a reboot restores stock networking"
}

# one-shot DNS restore — un-stick DNS no matter what rough state it's in (crash,
# forced kill, an old networksetup override, Tailscale DNS left paused). Safe to
# run anytime; it only ever moves DNS back toward normal.
_tthr_dnsreset_body() {
  # drop our scutil override, if present
  scutil >/dev/null 2>&1 <<EOF
remove State:/Network/Service/$_TTHR_SCUTIL_SVC/IPv4
remove State:/Network/Service/$_TTHR_SCUTIL_SVC/DNS
quit
EOF
  # clear any 1.1.1.1/1.0.0.1 override an older version left on a real service
  networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | while IFS= read -r svc; do
    case "$svc" in \**) continue ;; esac
    case "$(networksetup -getdnsservers "$svc" 2>/dev/null)" in
      *1.1.1.1*|*1.0.0.1*) networksetup -setdnsservers "$svc" Empty 2>/dev/null ;;
    esac
  done
  # make sure Tailscale is back in charge of its own DNS (no-op if already on)
  command -v tailscale >/dev/null 2>&1 && tailscale set --accept-dns=true 2>/dev/null
  dscacheutil -flushcache 2>/dev/null; killall -HUP mDNSResponder 2>/dev/null
  _tthr_log "dns-reset: applied"
}

_tthr_dnsreset() {
  if [ "$(id -u)" != "0" ]; then echo "✗ run:  sudo ./mooch.sh dns-reset"; return 1; fi
  echo "resetting DNS to normal..."
  _tthr_dnsreset_body
  echo "✓ DNS reset — scutil override cleared, services back to DHCP, Tailscale DNS on, cache flushed"
}

# =============================================================================
# PROBES  —  shared by check / watch / test / the transparent hold loop
# =============================================================================
# Every probe is a curl, never ping: ICMP doesn't cross the SOCKS tunnel, so
# ping fails while the web works. curl answers the same question ping would
# (alive? how slow?) via %{time_total}, and it can test DNS separately from
# transport — which matters here because the two fail independently (that is
# the whole bug history of this tool).
_TTHR_PROBE_TMO=5      # per-request timeout; SOCKS→USB→cellular is slow, 2s flapped
_TTHR_BURST_ROUNDS=3   # confirmation rounds after a state change
_TTHR_BURST_GAP=3      # seconds between rounds (macOS needs ~4s to settle DNS/primary)
_TTHR_HEALTH_IV=10     # transparent hold loop: seconds between health probes
_TTHR_WATCH_HB=30      # watch: heartbeat probe when nothing local has changed

_tthr_wifi_dev() {
  local d
  d=$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; print $NF; exit}')
  echo "${d:-en0}"
}
_tthr_resolver1() { scutil --dns 2>/dev/null | awk '/^resolver #1/{f=1} f&&/nameserver\[0\]/{print $3; exit}'; }
_tthr_route_if()  { route -n get default 2>/dev/null | awk '/interface:/{print $2}'; }

# transport: literal IP, no DNS involved. prints "<exit-ip> <ms>", or nothing.
_tthr_p_transport() {
  local out ip t
  out=$(curl -4 -s --max-time "$_TTHR_PROBE_TMO" -w '\n%{time_total}' https://1.1.1.1/cdn-cgi/trace 2>/dev/null)
  ip=$(printf '%s\n' "$out" | awk -F= '/^ip=/{print $2}')
  t=$(printf '%s\n' "$out" | tail -n 1)
  [ -n "$ip" ] && echo "$ip $(awk -v s="${t:-0}" 'BEGIN{printf "%d", s*1000}')"
}

# DNS through the SYSTEM resolver (the one apps use), cache-proof: a hostname
# nobody has ever resolved, so a stale cache can't fake a pass. Bounded by
# --max-time. prints "ok <ms>" or "fail <curl-rc>" (rc 6 = couldn't resolve).
_tthr_p_dns() {
  local name out rc us
  name="t$(date +%s)p$$${1:-}.1.1.1.1.sslip.io"
  out=$(curl -4 -sk -o /dev/null --max-time "$_TTHR_PROBE_TMO" -w '%{time_namelookup}' "https://$name/cdn-cgi/trace" 2>/dev/null); rc=$?
  us=$(awk -v s="${out:-0}" 'BEGIN{printf "%d", s*1000000}')
  if [ "$rc" != 6 ] && [ "$us" -gt 0 ]; then echo "ok $((us/1000))"; else echo "fail $rc"; fi
}

# the phone's OWN public exit IP, fetched through its SOCKS proxy over the adb
# forward. Carrier-agnostic replacement for the old "172.56.* means cellular"
# guess: if the Mac's exit IP equals this, the Mac is exiting via the phone.
_tthr_p_phone_ip() {
  curl -4 -s --max-time "$_TTHR_PROBE_TMO" --proxy "socks5h://$_TTHR_HOST:$_TTHR_SOCKS_PORT" \
       https://1.1.1.1/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}'
}

# which interface the PHONE is using for internet right now, from its own
# routing table via adb:  wifi | cell | none | ? | <raw dev>.  Stage D needs "cell".
_tthr_p_phone_uplink() {
  local dev
  [ "$(adb get-state 2>/dev/null)" = device ] || { echo "?"; return; }
  dev=$(adb shell ip route get 1.1.1.1 2>/dev/null | tr -d '\r' | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  case "$dev" in
    "")                                  echo "none" ;;
    wlan*)                               echo "wifi" ;;
    rmnet*|ccmni*|pdp*|ppp*|qmi*|seth*)  echo "cell" ;;
    *)                                   echo "$dev" ;;
  esac
}

# the adb SOCKS forward — forwards silently vanish when the cable is re-plugged
_tthr_fwd_up() { adb forward --list 2>/dev/null | grep -q "tcp:$_TTHR_SOCKS_PORT tcp:$_TTHR_PHONE_SOCKS_PORT"; }
_tthr_fwd_ensure() {
  [ "$(adb get-state 2>/dev/null)" = device ] || return 1
  _tthr_fwd_up && return 0
  adb forward tcp:$_TTHR_SOCKS_PORT tcp:$_TTHR_PHONE_SOCKS_PORT >/dev/null 2>&1
}

# one line explaining WHY transport is dead right now. Walks the chain in order:
# route → adb → forward → tun2socks → phone SOCKS → phone data path.
_tthr_diagnose() {
  local rif rc
  rif=$(_tthr_route_if)
  [ -z "$rif" ] && { echo "no default route at all"; return; }
  case "$rif" in
    utun*)
      [ "$(adb get-state 2>/dev/null)" = device ] || { echo "route is on $rif but phone is NOT on adb (cable out? USB debugging off? adb server died?)"; return; }
      _tthr_fwd_up || { echo "phone on adb but adb forward tcp:$_TTHR_SOCKS_PORT is gone (forwards drop on re-plug; transparent mode restores it within ${_TTHR_HEALTH_IV}s)"; return; }
      pgrep -f tun2socks >/dev/null 2>&1 || { echo "tun2socks is not running but the default route still points at $rif"; return; }
      curl -4 -s -o /dev/null --max-time "$_TTHR_PROBE_TMO" --proxy "socks5h://$_TTHR_HOST:$_TTHR_SOCKS_PORT" https://1.1.1.1/cdn-cgi/trace 2>/dev/null; rc=$?
      case "$rc" in
        0)  echo "phone SOCKS5 answers directly, but traffic via $rif does not → tun2socks/route problem (see $_TTHR_STATE/t2s.log)" ;;
        7)  echo "cannot connect to 127.0.0.1:$_TTHR_SOCKS_PORT — the adb forward accepts nothing (adb server hung? try: adb kill-server)" ;;
        97) echo "SOCKS5 handshake failed (curl rc 97) — Every Proxy is reachable but the PHONE has no data path (phone uplink: $(_tthr_p_phone_uplink))" ;;
        28) echo "SOCKS5 timed out (curl rc 28) — phone data stalled or very slow (phone uplink: $(_tthr_p_phone_uplink))" ;;
        *)  echo "Every Proxy not answering on phone port $_TTHR_PHONE_SOCKS_PORT (curl rc $rc) — is SOCKS5 enabled in Every Proxy?" ;;
      esac ;;
    *)
      [ -n "$(ipconfig getifaddr "$rif" 2>/dev/null)" ] || { echo "default route is on $rif but it has no IPv4 address"; return; }
      echo "default route is on $rif (normal path, not mooch) — upstream/ISP/captive-portal problem" ;;
  esac
}

# one line explaining WHY names don't resolve even though transport works
_tthr_diagnose_dns() {
  local r1
  r1=$(_tthr_resolver1)
  case "$r1" in
    1.1.1.1|1.0.0.1) echo "resolver #1 is $r1 (mooch's) but lookups fail — DNS isn't crossing the tunnel (UDP via tun2socks?) try: nslookup example.com 1.1.1.1" ;;
    100.100.100.100) echo "resolver #1 is Tailscale ($r1) — it forwards to a LAN gateway that's unreachable now; run: sudo ./mooch.sh dns-reset" ;;
    "")              echo "there is no resolver #1 at all" ;;
    *) if [ -z "$(ipconfig getifaddr "$(_tthr_wifi_dev)" 2>/dev/null)" ]; then
         echo "resolver #1 is $r1 (the Wi-Fi/LAN resolver) while Wi-Fi is DOWN → unreachable; mooch's DNS pin did not stick"
       else
         echo "resolver #1 is $r1 (Wi-Fi's) and Wi-Fi is up, yet lookups fail — that resolver isn't answering"
       fi ;;
  esac
}

# describe the exit for a given Mac exit IP ($1): via the phone or not, and is
# the phone on cell. Pass phone ip/uplink as $2/$3 if you already fetched them.
_tthr_exit_tag() {
  local ip="$1" pip pup rif tun=0
  if [ $# -ge 2 ]; then pip="$2"; pup="$3"; else pip=$(_tthr_p_phone_ip); pup=$(_tthr_p_phone_uplink); fi
  rif=$(_tthr_route_if)
  case "$rif" in utun*) tun=1 ;; esac
  [ -n "${ALL_PROXY:-}${HTTPS_PROXY:-}" ] && tun=1   # proxy mode: this shell's curl goes via the phone too
  if [ -z "$pip" ]; then
    echo "exit $ip — phone's exit unknown (no SOCKS answer via forward; phone uplink: $pup)"
  elif [ "$ip" = "$pip" ] && [ "$tun" = 1 ]; then
    case "$pup" in
      cell) echo "exit $ip = phone's exit, phone on CELLULAR 📱  ← the goal" ;;
      wifi) echo "exit $ip = phone's exit, but the phone is on WI-FI (turn phone Wi-Fi off for real 5G)" ;;
      *)    echo "exit $ip = phone's exit (phone uplink: $pup)" ;;
    esac
  elif [ "$ip" = "$pip" ]; then
    echo "exit $ip — same IP as the phone, but route is $rif: both are on the same Wi-Fi, Mac is NOT via phone 🛜"
  else
    echo "exit $ip ≠ phone's $pip → NOT leaving via the phone 🛜 (route $rif, phone uplink: $pup)"
  fi
}

# confirmation burst — N rounds of transport+DNS, spaced out, so one slow request
# during macOS's settle window doesn't read as "down". Prints a verdict line
# (UP / FLAKY / DNS DOWN / DOWN) with a "why", appends it to logfile $1, and sets
# _TTHR_LAST_UP (1/0) for the watch heartbeat.
_tthr_burst() {
  local logf="$1" rounds="$_TTHR_BURST_ROUNDS" i t d tok=0 dok=0 sum=0 ip="" lat verdict why="" line
  for i in $(seq 1 "$rounds"); do
    t=$(_tthr_p_transport)
    if [ -n "$t" ]; then tok=$((tok+1)); ip=${t%% *}; lat=${t##* }; sum=$((sum+lat)); fi
    d=$(_tthr_p_dns "r$i")
    case "$d" in ok*) dok=$((dok+1)) ;; esac
    [ "${_TTHR_STOP:-0}" = 1 ] && break
    [ "$i" -lt "$rounds" ] && sleep "$_TTHR_BURST_GAP"
  done
  if   [ "$tok" = 0 ]; then verdict="DOWN";     why=$(_tthr_diagnose)
  elif [ "$dok" = 0 ]; then verdict="DNS DOWN"; why=$(_tthr_diagnose_dns)
  elif [ "$tok" = "$rounds" ] && [ "$dok" = "$rounds" ]; then verdict="UP"
  else verdict="FLAKY"; why="$((rounds-tok)) transport / $((rounds-dok)) dns round(s) failed — lag or an unstable link, not a config problem"
  fi
  if [ "$tok" -gt 0 ]; then _TTHR_LAST_UP=1; else _TTHR_LAST_UP=0; fi
  line="   ↳ [$(date '+%H:%M:%S')] transport $tok/$rounds"
  [ "$tok" -gt 0 ] && line="$line (avg $((sum/tok))ms)"
  line="$line  dns $dok/$rounds  → $verdict"
  [ -n "$ip" ] && line="$line  |  $(_tthr_exit_tag "$ip")"
  echo "$line"; [ -n "$logf" ] && printf '%s\n' "$line" >> "$logf" 2>/dev/null
  if [ -n "$why" ]; then
    echo "     why: $why"; [ -n "$logf" ] && printf '%s\n' "     why: $why" >> "$logf" 2>/dev/null
  fi
}

# quick connectivity check — run in ANY state (no sudo). Tests transport and DNS
# separately so you can see which layer is up, and where you're exiting.
_tthr_check() {
  local rif t ip lat d pip pup r1
  rif=$(_tthr_route_if)
  echo "── default route ──"
  echo "  via ${rif:-none}"
  echo "── phone ──"
  if [ "$(adb get-state 2>/dev/null)" = device ]; then
    _tthr_fwd_ensure >/dev/null 2>&1
    pup=$(_tthr_p_phone_uplink); pip=$(_tthr_p_phone_ip)
    echo "  on adb: yes   uplink: $pup   phone's own exit IP: ${pip:-<SOCKS not answering via forward>}"
  else
    pup="?"; pip=""
    echo "  on adb: NO — plug in USB / enable USB debugging"
  fi
  echo "── transport (raw IP 1.1.1.1, no DNS needed) ──"
  t=$(_tthr_p_transport)
  if [ -n "$t" ]; then
    ip=${t%% *}; lat=${t##* }
    echo "  ✓ internet reachable in ${lat}ms — $(_tthr_exit_tag "$ip" "$pip" "$pup")"
  else
    echo "  ✗ NO transport — there is no path to the internet right now"
    echo "     why: $(_tthr_diagnose)"
  fi
  echo "── DNS (system resolver, cache-proof name) ──"
  d=$(_tthr_p_dns c)
  case "$d" in
    ok*) echo "  ✓ names resolve (${d#ok }ms) — full internet works" ;;
    *)   echo "  ✗ DNS not resolving (curl rc ${d#fail })$([ -n "$t" ] && echo ' — even though transport above is ✓')"
         echo "     why: $(_tthr_diagnose_dns)" ;;
  esac
  # diagnostics: WHICH resolver is primary, and is 1.1.1.1 reachable via tunnel?
  r1=$(_tthr_resolver1)
  case "$r1" in
    1.1.1.1|1.0.0.1) echo "  primary resolver : $r1  (mooch's tunnel DNS ✓)" ;;
    100.100.100.100) echo "  primary resolver : $r1  (Tailscale — should be paused while mooch runs)" ;;
    "")              echo "  primary resolver : <none>" ;;
    *)               echo "  primary resolver : $r1" ;;
  esac
  if nslookup -timeout=5 example.com 1.1.1.1 >/dev/null 2>&1; then
    echo "  raw 1.1.1.1 test : ✓ resolves through the tunnel (DNS path itself is fine)"
  else
    echo "  raw 1.1.1.1 test : ✗ not resolving through the tunnel"
  fi
  echo
  echo "  note: 'ping' is NOT a valid test for mooch — ICMP doesn't cross the SOCKS"
  echo "        tunnel, so ping fails while web traffic works. Use this check instead."
}

# --- passive state monitor (no sudo) -----------------------------------------
# Polls LOCAL network state every N seconds and prints a line ONLY when something
# changes, then runs a confirmation burst (3× transport+DNS over ~6s) and prints
# one settled ↳ verdict — UP / FLAKY / DNS DOWN / DOWN — with a one-line "why"
# that walks the chain (route → adb → forward → tun2socks → phone SOCKS → phone
# data). The exit IP is deliberately NOT part of the change signature: a single
# slow request used to count as a "change" and spam the timeline.
# Between changes a heartbeat probe fires every 30s and only speaks up if the
# link's up/down state disagrees with the last verdict (catches silent death,
# e.g. the carrier dropping while nothing local moved).
# Touches nothing on the Mac's routing/DNS; it only makes sure the adb SOCKS
# forward exists so it can read the phone's own exit IP. Ctrl+C to stop.
#   ./mooch.sh watch [seconds]        log: /tmp/mooch-watch.log
_TTHR_WATCH_LOG=/tmp/mooch-watch.log
_tthr_watch() {
  local iv="${2:-2}"
  _TTHR_STOP=0; _TTHR_LAST_UP=""
  trap '_TTHR_STOP=1' INT TERM
  local wdev; wdev=$(_tthr_wifi_dev)
  _tthr_fwd_ensure >/dev/null 2>&1

  echo "▶ watching network state every ${iv}s — Ctrl+C to stop"
  echo "  log: $_TTHR_WATCH_LOG"
  echo "  columns:  phone:<adb?>/<phone-uplink>  wifi:<radio>(<ip>)  route:<if>/<gw>  fwd:<adb-forward?>  tun:<tun2socks?>  dns:<resolver#1>  ts:<tailscale-dns>"
  echo "  every change is followed by a ↳ verdict: transport N/3 (latency), dns N/3, and where you're exiting"
  echo "  ───────────────────────────────────────────────────────────────────────"
  printf '%s\n' "─── watch started $(date '+%Y-%m-%d %H:%M:%S') (interval ${iv}s) ───" >> "$_TTHR_WATCH_LOG" 2>/dev/null

  local last="" first=1 idle=0
  local phone wpwr wip rget rif rgw fwd t2s res tsd sig note line t dir
  while [ "$_TTHR_STOP" = 0 ]; do
    if [ "$(adb get-state 2>/dev/null)" = device ]; then phone="usb/$(_tthr_p_phone_uplink)"; else phone="no"; fi
    wpwr=$(networksetup -getairportpower "$wdev" 2>/dev/null | awk '{print $NF}'); [ -z "$wpwr" ] && wpwr="?"
    wip=$(ipconfig getifaddr "$wdev" 2>/dev/null); [ -z "$wip" ] && wip="-"
    rget=$(route -n get default 2>/dev/null)
    rif=$(echo "$rget" | awk '/interface:/{print $2}'); [ -z "$rif" ] && rif="none"
    rgw=$(echo "$rget" | awk '/gateway:/{print $2}');   [ -z "$rgw" ] && rgw="-"
    if _tthr_fwd_up; then fwd="yes"; else fwd="no"; fi
    if pgrep -f tun2socks >/dev/null 2>&1; then t2s="YES"; else t2s="no"; fi
    res=$(_tthr_resolver1); [ -z "$res" ] && res="-"
    if command -v tailscale >/dev/null 2>&1; then
      case "$(tailscale debug prefs 2>/dev/null | grep -i CorpDNS)" in
        *true*) tsd="on" ;; *false*) tsd="off" ;; *) tsd="?" ;;
      esac
    else tsd="na"; fi

    sig="$phone|$wpwr|$wip|$rif|$rgw|$fwd|$t2s|$res|$tsd"
    if [ "$sig" != "$last" ]; then
      note=""; [ "$first" = 1 ] && note="   ← baseline"
      line=$(printf '[%s] phone:%s  wifi:%s(%s)  route:%s/%s  fwd:%s  tun:%s  dns:%s  ts:%s%s' \
             "$(date '+%H:%M:%S')" "$phone" "$wpwr" "$wip" "$rif" "$rgw" "$fwd" "$t2s" "$res" "$tsd" "$note")
      echo "$line"
      printf '%s\n' "$line" >> "$_TTHR_WATCH_LOG" 2>/dev/null
      last="$sig"; first=0; idle=0
      _tthr_burst "$_TTHR_WATCH_LOG"
    else
      idle=$((idle+iv))
      if [ "$idle" -ge "$_TTHR_WATCH_HB" ]; then
        idle=0
        t=$(_tthr_p_transport)
        if { [ -n "$t" ] && [ "$_TTHR_LAST_UP" = 0 ]; } || { [ -z "$t" ] && [ "$_TTHR_LAST_UP" = 1 ]; }; then
          if [ -n "$t" ]; then dir=UP; else dir=DOWN; fi
          line="[$(date '+%H:%M:%S')] heartbeat: link went $dir with NO local change — confirming"
          echo "$line"; printf '%s\n' "$line" >> "$_TTHR_WATCH_LOG" 2>/dev/null
          _tthr_burst "$_TTHR_WATCH_LOG"
        fi
      fi
    fi
    [ "$_TTHR_STOP" = 0 ] && sleep "$iv"
  done
  echo; echo "■ watch stopped (routing/DNS untouched)"
}

# --- deterministic, self-grading stage test (no sudo) --------------------------
#   ./mooch.sh test <A|B|C|D|E>
# Same command at every stage; it runs the probes and grades them against what
# that stage SHOULD show, naming exactly which probe failed. The site lookup is
# cache-proof: it resolves a hostname nobody has ever seen (so a stale DNS cache
# can't fake a pass) AND fetches google.com by name (DNS + transport end-to-end).
#   A  normal        Wi-Fi on,  mooch off, phone on Wi-Fi
#   B  mooch up      Wi-Fi on,  mooch on,  phone on Wi-Fi
#   C  DNS test      Wi-Fi OFF, mooch on,  phone on Wi-Fi   → resolver must be 1.1.1.1
#   D  REAL 5G       Wi-Fi OFF, mooch on,  phone Wi-Fi OFF  → exit must be the PHONE's, phone on cell
#   E  torn down     back to A
# "Via the phone" is decided carrier-agnostically: the Mac's exit IP must equal
# the phone's own exit IP (fetched through its SOCKS proxy), and the phone's own
# routing table (via adb) must say it's on a cellular interface for stage D.
_tthr_test() {
  local stage; stage=$(echo "${2:-}" | tr a-z A-Z)
  local rif res t exip lat d fresh site pip pup
  _tthr_fwd_ensure >/dev/null 2>&1
  rif=$(_tthr_route_if); [ -z "$rif" ] && rif=none
  res=$(_tthr_resolver1); [ -z "$res" ] && res=none
  t=$(_tthr_p_transport)
  if [ -n "$t" ]; then exip=${t%% *}; lat=${t##* }; else exip=offline; lat=-; fi
  d=$(_tthr_p_dns t)
  case "$d" in ok*) fresh="ok (${d#ok }ms)" ;; *) fresh="FAIL (curl rc ${d#fail })" ;; esac
  # a real site, by NAME (DNS + transport end-to-end, what apps actually do)
  site=$(curl -4 -s -o /dev/null -w '%{http_code}' --max-time 10 https://www.google.com 2>/dev/null); [ -z "$site" ] && site=000
  pip=$(_tthr_p_phone_ip); [ -z "$pip" ] && pip=unknown
  pup=$(_tthr_p_phone_uplink)

  echo "── probes ──"
  echo "  route        : $rif"
  echo "  resolver #1  : $res"
  echo "  fresh DNS    : $fresh   ← cache-proof lookup via the system resolver"
  echo "  google.com   : HTTP $site   ← looked up by name"
  echo "  exit IP      : $exip  (${lat}ms)"
  echo "  phone        : exit IP $pip, uplink $pup   ← via adb + SOCKS forward"
  if [ "$exip" != offline ]; then echo "  verdict      : $(_tthr_exit_tag "$exip" "$([ "$pip" != unknown ] && echo "$pip")" "$pup")"; fi
  [ -z "$stage" ] && { echo; echo "  grade it against a stage:  ./mooch.sh test A|B|C|D|E"; return 0; }

  local fail="" dnsok=0 siteok=0 tunnel=0 ours=0 viaphone=0
  case "$d"    in ok*)   dnsok=1 ;; esac
  case "$site" in 2*|3*) siteok=1 ;; esac
  case "$rif"  in utun*) tunnel=1 ;; esac
  case "$res"  in 1.1.1.1|1.0.0.1) ours=1 ;; esac
  [ "$exip" != offline ] && [ "$pip" != unknown ] && [ "$exip" = "$pip" ] && viaphone=1
  case "$stage" in
    A|E)
      [ "$tunnel" = 0 ] || fail="$fail route(want wifi, got $rif);"
      [ "$dnsok"  = 1 ] || fail="$fail freshDNS;"
      [ "$siteok" = 1 ] || fail="$fail site(HTTP $site);"
      [ "$exip" != offline ] || fail="$fail exit(offline);" ;;
    B)
      [ "$tunnel"   = 1 ] || fail="$fail route(want utun, got $rif);"
      [ "$dnsok"    = 1 ] || fail="$fail freshDNS;"
      [ "$siteok"   = 1 ] || fail="$fail site(HTTP $site);"
      [ "$viaphone" = 1 ] || fail="$fail exit(want phone's $pip, got $exip);" ;;
    C)
      [ "$tunnel"   = 1 ] || fail="$fail route(want utun, got $rif);"
      [ "$ours"     = 1 ] || fail="$fail resolver(want 1.1.1.1, got $res);"
      [ "$dnsok"    = 1 ] || fail="$fail freshDNS;"
      [ "$siteok"   = 1 ] || fail="$fail site(HTTP $site);"
      [ "$viaphone" = 1 ] || fail="$fail exit(want phone's $pip, got $exip);" ;;
    D)
      [ "$tunnel"   = 1 ] || fail="$fail route(want utun, got $rif);"
      [ "$ours"     = 1 ] || fail="$fail resolver(want 1.1.1.1, got $res);"
      [ "$dnsok"    = 1 ] || fail="$fail freshDNS;"
      [ "$siteok"   = 1 ] || fail="$fail site(HTTP $site);"
      [ "$viaphone" = 1 ] || fail="$fail exit(want phone's $pip, got $exip);"
      [ "$pup"   = cell ] || fail="$fail phone-uplink(want cell, got $pup — turn the PHONE's Wi-Fi off);" ;;
    *) echo; echo "  unknown stage '$stage' — use A|B|C|D|E"; return 1 ;;
  esac
  echo
  if [ -z "$fail" ]; then echo "  ✅ STAGE $stage  PASS"
  else echo "  ❌ STAGE $stage  FAIL —$fail"; fi
  [ "$exip" = offline ] && echo "     why: $(_tthr_diagnose)"
  [ "$exip" != offline ] && [ "$dnsok" = 0 ] && echo "     why: $(_tthr_diagnose_dns)"
  return 0
}

case "${1:-status}" in
  on)          _tthr_on ;;
  off)         _tthr_off ;;
  status)      _tthr_status ;;
  browser)     _tthr_browser "$@" ;;
  transparent) _tthr_transparent ;;
  panic)       _tthr_panic ;;
  dns-reset|dnsreset) _tthr_dnsreset ;;
  check)       _tthr_check ;;
  watch)       _tthr_watch "$@" ;;
  test)        _tthr_test "$@" ;;
  *)           echo "usage:"
               echo "  ./mooch.sh check                                (transport + DNS + which exit, with a why; any state)"
               echo "  ./mooch.sh watch [seconds]                      (live timeline; each change gets a 3-probe verdict)"
               echo "  ./mooch.sh test A|B|C|D|E                       (self-grading stage test, PASS/FAIL)"
               echo "  source ./mooch.sh on|off|status|browser [url]   (per-app proxy)"
               echo "  sudo   ./mooch.sh transparent                   (route ALL traffic via phone)"
               echo "  sudo   ./mooch.sh panic                         (force-remove everything)"
               echo "  sudo   ./mooch.sh dns-reset                     (un-stick DNS if names stop resolving)" ;;
esac
