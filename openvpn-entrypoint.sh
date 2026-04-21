#!/bin/bash
set -euo pipefail

cd /etc/openvpn

shopt -s nullglob
configs=( *.conf )
if [ "${#configs[@]}" -ne 1 ]; then
  echo "expected exactly one .conf file in /etc/openvpn, found ${#configs[@]}" >&2
  exit 1
fi

config="${configs[0]}"

has_directive() {
  local key="$1"
  grep -Eq "^[[:space:]]*${key}([[:space:]]|$)" "$config"
}

args=(
  --config "$config"
  --script-security 2
  --up /usr/local/bin/sockd.sh
  --down /usr/local/bin/sockd-down.sh
  --down-pre
  --up-restart
)

if ! has_directive "ping"; then
  args+=( --ping "${OPENVPN_PING:-10}" )
fi

if ! has_directive "ping-restart"; then
  args+=( --ping-restart "${OPENVPN_PING_RESTART:-60}" )
fi

if ! has_directive "connect-retry"; then
  args+=( --connect-retry "${OPENVPN_CONNECT_RETRY_DELAY:-5}" "${OPENVPN_CONNECT_RETRY_MAX:-60}" )
fi

if ! has_directive "connect-timeout"; then
  args+=( --connect-timeout "${OPENVPN_CONNECT_TIMEOUT:-30}" )
fi

if ! has_directive "resolv-retry"; then
  args+=( --resolv-retry "${OPENVPN_RESOLV_RETRY:-infinite}" )
fi

if [ -n "${OPENVPN_EXTRA_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  extra_args=( ${OPENVPN_EXTRA_ARGS} )
  args+=( "${extra_args[@]}" )
fi

watchdog_pid=""
cleanup() {
  if [ -n "$watchdog_pid" ]; then
    kill "$watchdog_pid" >/dev/null 2>&1 || true
    wait "$watchdog_pid" 2>/dev/null || true
  fi
}

trap cleanup EXIT

/usr/local/bin/openvpn-watchdog.sh &
watchdog_pid=$!

while true; do
  /usr/sbin/openvpn "${args[@]}" &
  openvpn_pid=$!
  wait "$openvpn_pid"
  sleep 1
done
