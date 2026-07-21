#!/usr/bin/env bash
# mooch.sh — route this Mac through the phone's on-device 5G via an on-phone
# HTTP proxy (Every Proxy) piped over the USB cable with adb.
#
# This is NOT tethering — the phone's proxy app fetches on-device, so the
# carrier's hotspot/tethering speed cap never applies. The Mac "mooches" the
# phone's own data path over the cable.
#
#   source ./mooch.sh on       turn everything ON  (adb pipe + browser + shell)
#   source ./mooch.sh off      turn everything OFF (full revert)
#   source ./mooch.sh status   show current state
#
# It must be SOURCED (not executed) so it can set/clear the proxy env vars in
# YOUR shell for Claude Code. The system-proxy (browser) parts work either way.
#
# What "on" changes, and what "off" reverts — nothing persists past `off`:
#   • adb forward tcp:8899  (Mac localhost:8899 -> phone:8080)
#   • macOS Web + Secure Web proxy on your active service -> 127.0.0.1:8899
#   • HTTP(S)_PROXY / ALL_PROXY / NO_PROXY exported in this shell
# Tailscale (100.64.0.0/10, *.ts.net) and localhost are always bypassed.

_TTHR_HOST=127.0.0.1
_TTHR_PORT=8899          # Mac-side local port (kept off 8080 to avoid dev servers)
_TTHR_PHONE_PORT=8080    # port Every Proxy's HTTP proxy listens on
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
  # 1b) local port free? (a dev server on this port would silently break the pipe)
  local holder
  holder=$(lsof -nP -iTCP:$_TTHR_PORT -sTCP:LISTEN 2>/dev/null | awk 'NR>1 && $1!="adb"{print $1; exit}')
  if [ -n "$holder" ]; then
    echo "✗ local port $_TTHR_PORT is already in use by '$holder' — the USB pipe can't bind cleanly."
    echo "  Change _TTHR_PORT at the top of mooch.sh to a free port, then retry."
    return 1
  fi
  # 2) USB pipe
  adb forward tcp:$_TTHR_PORT tcp:$_TTHR_PHONE_PORT >/dev/null || { echo "✗ adb forward failed"; return 1; }
  # 3) is the phone proxy actually listening? (don't set a dead proxy)
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --proxy http://$_TTHR_HOST:$_TTHR_PORT \
         --connect-timeout 6 --max-time 10 "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null)
  if [ "$code" != "200" ]; then
    echo "✗ proxy not answering on the phone (got '$code')."
    echo "  Open Every Proxy and toggle the HTTP proxy ON (port $_TTHR_PHONE_PORT)."
    adb forward --remove tcp:$_TTHR_PORT 2>/dev/null
    return 1
  fi
  # 4) browser / system proxy
  local svc; svc=$(_tthr_service); [ -z "$svc" ] && svc="Wi-Fi"
  networksetup -setwebproxy         "$svc" "$_TTHR_HOST" "$_TTHR_PORT" 2>/dev/null
  networksetup -setsecurewebproxy   "$svc" "$_TTHR_HOST" "$_TTHR_PORT" 2>/dev/null
  networksetup -setproxybypassdomains "$svc" localhost 127.0.0.1 "*.ts.net" "100.64.0.0/10" 2>/dev/null
  networksetup -setwebproxystate       "$svc" on 2>/dev/null
  networksetup -setsecurewebproxystate "$svc" on 2>/dev/null
  # 5) shell / Claude Code
  if _tthr_sourced; then
    export HTTP_PROXY="http://$_TTHR_HOST:$_TTHR_PORT" HTTPS_PROXY="http://$_TTHR_HOST:$_TTHR_PORT" ALL_PROXY="http://$_TTHR_HOST:$_TTHR_PORT"
    export http_proxy="$HTTP_PROXY" https_proxy="$HTTPS_PROXY" all_proxy="$ALL_PROXY"
    export NO_PROXY="$_TTHR_NOPROXY" no_proxy="$_TTHR_NOPROXY"
  fi
  echo "✓ mooch ON  (service: $svc)  — browser + Claude Code now ride on-device 5G"
  _tthr_sourced || echo "  note: run with 'source' to also set HTTPS_PROXY for Claude Code in this shell"
}

_tthr_off() {
  local svc; svc=$(_tthr_service); [ -z "$svc" ] && svc="Wi-Fi"
  networksetup -setwebproxystate       "$svc" off 2>/dev/null
  networksetup -setsecurewebproxystate "$svc" off 2>/dev/null
  adb forward --remove tcp:$_TTHR_PORT 2>/dev/null
  if _tthr_sourced; then
    unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy NO_PROXY no_proxy
  fi
  echo "✓ mooch OFF (service: $svc)  — back to normal Wi-Fi, all proxy settings cleared"
}

_tthr_status() {
  local svc; svc=$(_tthr_service); [ -z "$svc" ] && svc="Wi-Fi"
  echo "network service : $svc"
  echo -n "system proxy    : "; networksetup -getsecurewebproxy "$svc" 2>/dev/null | awk 'NR<=3{printf "%s ",$0} END{print ""}'
  echo    "shell HTTPS_PROXY: ${HTTPS_PROXY:-<unset>}"
  echo -n "adb forward     : "; adb forward --list 2>/dev/null | grep ":$_TTHR_PORT " || echo "<none>"
  echo -n "proxy reachable : "
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' --proxy http://$_TTHR_HOST:$_TTHR_PORT --max-time 8 "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null)
  [ "$code" = "200" ] && echo "yes (proxy up)" || echo "no (proxy down / off)"
}

# --- launch a Chrome that proxies through the phone, Wi-Fi or not -------------
# Uses a dedicated profile + the --proxy-server flag so it works even with
# Wi-Fi off (unlike the macOS system proxy, which dies with the Wi-Fi service).
_tthr_browser() {
  local url="${2:-https://1.1.1.1/cdn-cgi/trace}"
  open -na "Google Chrome" --args \
    --proxy-server="http://$_TTHR_HOST:$_TTHR_PORT" \
    --user-data-dir="$HOME/.mooch-chrome" \
    "$url" 2>/dev/null \
    && echo "✓ opened a proxied Chrome window (via $_TTHR_HOST:$_TTHR_PORT) — survives Wi-Fi off" \
    || echo "✗ couldn't launch Chrome"
}

case "${1:-status}" in
  on)      _tthr_on ;;
  off)     _tthr_off ;;
  status)  _tthr_status ;;
  browser) _tthr_browser "$@" ;;
  *)       echo "usage: source ./mooch.sh on|off|status|browser [url]" ;;
esac
