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

case "${1:-status}" in
  on)      _tthr_on ;;
  off)     _tthr_off ;;
  status)  _tthr_status ;;
  browser) _tthr_browser "$@" ;;
  *)       echo "usage: source ./mooch.sh on|off|status|browser [url]" ;;
esac
