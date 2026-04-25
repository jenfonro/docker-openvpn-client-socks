#!/bin/bash
set -euo pipefail

interval="${WATCHDOG_INTERVAL:-30}"
failures_max="${WATCHDOG_FAILURES:-3}"

failures=0
managed_mode=0
if [ -n "${TARGET_COUNTRY:-}" ]; then
  managed_mode=1
fi

openvpn_running() {
  pgrep -f '^/usr/sbin/openvpn( |$)' >/dev/null 2>&1
}

health_ok() {
  /usr/local/bin/vpngate-manager.sh health >/dev/null 2>&1
}

restart_openvpn_only() {
  pkill -TERM -f '^/usr/sbin/openvpn( |$)' >/dev/null 2>&1 || true
}

while true; do
  sleep "$interval"

  if ! openvpn_running; then
    failures=0
    continue
  fi

  if health_ok; then
    failures=0
    continue
  fi

  failures=$((failures + 1))
  echo "watchdog: connectivity check failed (${failures}/${failures_max})" >&2

  if [ "$failures" -lt "$failures_max" ]; then
    continue
  fi

  if [ "$managed_mode" -eq 1 ]; then
    echo "watchdog: threshold reached, rotating config pool for ${TARGET_COUNTRY}" >&2
    if /usr/local/bin/vpngate-manager.sh rotate; then
      echo "watchdog: rotation succeeded" >&2
    else
      echo "watchdog: rotation failed (all candidates exhausted)" >&2
    fi
  else
    echo "watchdog: restarting openvpn process" >&2
    restart_openvpn_only
  fi

  failures=0
done
