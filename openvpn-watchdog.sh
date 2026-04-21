#!/bin/bash
set -euo pipefail

interval="${WATCHDOG_INTERVAL:-30}"
timeout="${WATCHDOG_TIMEOUT:-15}"
failures_max="${WATCHDOG_FAILURES:-3}"
test_url="${WATCHDOG_TEST_URL:-https://api.ipify.org}"
direct_test_url="${WATCHDOG_DIRECT_TEST_URL:-$test_url}"
require_different_ip="${WATCHDOG_REQUIRE_DIFFERENT_IP:-1}"
require_tun_route="${WATCHDOG_REQUIRE_TUN_ROUTE:-1}"

failures=0

get_default_proxy_url() {
  local eth0_ip
  eth0_ip="$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | head -n1)"
  if [ -n "$eth0_ip" ]; then
    echo "socks5://${eth0_ip}:1080"
  else
    echo "socks5://127.0.0.1:1080"
  fi
}

proxy_url="${WATCHDOG_PROXY_URL:-$(get_default_proxy_url)}"

openvpn_running() {
  # BusyBox pgrep -x does not match this process reliably in Alpine.
  pgrep -f '^/usr/sbin/openvpn( |$)' >/dev/null 2>&1
}

trim_output() {
  tr -d '\r\n[:space:]'
}

probe_proxy() {
  curl -sS --max-time "$timeout" --proxy "$proxy_url" "$test_url" 2>/dev/null | trim_output
}

probe_direct() {
  curl -sS --max-time "$timeout" "$direct_test_url" 2>/dev/null | trim_output
}

healthy() {
  local proxy_ip direct_ip

  proxy_ip="$(probe_proxy)" || return 1
  [ -n "$proxy_ip" ] || return 1

  if [ "$require_tun_route" = "1" ]; then
    ip route get 1.1.1.1 2>/dev/null | grep -q "dev tun" || return 1
  fi

  if [ "$require_different_ip" = "1" ]; then
    direct_ip="$(probe_direct)" || return 1
    [ -n "$direct_ip" ] || return 1
    [ "$proxy_ip" != "$direct_ip" ] || return 1
  fi

  return 0
}

while true; do
  sleep "$interval"

  if ! openvpn_running; then
    failures=0
    continue
  fi

  if healthy; then
    failures=0
    continue
  fi

  failures=$((failures + 1))
  echo "watchdog: connectivity check failed (${failures}/${failures_max})" >&2

  if [ "$failures" -lt "$failures_max" ]; then
    continue
  fi

  echo "watchdog: restarting openvpn process" >&2
  # Match full command path; BusyBox proc name matching with -x is unreliable here.
  pkill -TERM -f '^/usr/sbin/openvpn( |$)' >/dev/null 2>&1 || true
  failures=0
done
