#!/usr/bin/env bash
# tether.sh — route this Mac through the phone's UNLIMITED on-device 5G via an
# on-phone HTTP proxy (Every Proxy) piped over the USB cable with adb.
#
# This is NOT tethering — the phone's proxy app fetches on-device, so the
# carrier's hotspot/tethering speed cap never applies.
#
#   source ./tether.sh on       turn everything ON  (adb pipe + browser + shell)
#   source ./tether.sh off      turn everything OFF (full revert)
#   source ./tether.sh status   show current state
#
# It must be SOURCED (not executed) so it can set/clear the proxy env vars in
# YOUR shell for Claude Code. The system-proxy (browser) parts work either way.
#
# What "on" changes, and what "off" reverts — nothing persists past `off`:
#   • adb forward tcp:8080  (Mac localhost:8080 -> phone:8080)
#   • macOS Web + Secure Web proxy on your active service -> 127.0.0.1:8080
#   • HTTP(S)_PROXY / ALL_PROXY / NO_PROXY exported in this shell
# Tailscale (100.64.0.0/10, *.ts.net) and localhost are always bypassed.

_TTHR_HOST=127.0.0.1
_TTHR_PORT=8080          # Mac-side local port
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
  echo "✓ tether ON  (service: $svc)  — browser + Claude Code now ride on-device 5G"
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
  echo "✓ tether OFF (service: $svc)  — back to normal Wi-Fi, all proxy settings cleared"
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

case "${1:-status}" in
  on)     _tthr_on ;;
  off)    _tthr_off ;;
  status) _tthr_status ;;
  *)      echo "usage: source ./tether.sh on|off|status" ;;
esac
