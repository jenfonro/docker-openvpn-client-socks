#!/bin/bash
set -euo pipefail

managed_mode=0
if [ -n "${TARGET_COUNTRY:-}" ]; then
  managed_mode=1
fi

resolve_config_file() {
  if [ "$managed_mode" -eq 1 ]; then
    export VP_ROOT="${VP_ROOT:-/opt/server/vpngate}"
    export OPENVPN_RUNTIME_CONF="${OPENVPN_RUNTIME_CONF:-/tmp/openvpn-client.conf}"

    /usr/local/bin/vpngate-manager.sh init

    if ! /usr/local/bin/vpngate-manager.sh prepare; then
      echo "failed to prepare runtime config for TARGET_COUNTRY=${TARGET_COUNTRY}" >&2
      exit 1
    fi

    echo "$OPENVPN_RUNTIME_CONF"
    return 0
  fi

  cd /etc/openvpn

  shopt -s nullglob
  local configs=( *.conf )
  if [ "${#configs[@]}" -ne 1 ]; then
    echo "expected exactly one .conf file in /etc/openvpn, found ${#configs[@]}" >&2
    exit 1
  fi

  echo "/etc/openvpn/${configs[0]}"
}

has_directive() {
  local key="$1"
  local file="$2"
  grep -Eq "^[[:space:]]*${key}([[:space:]]|$)" "$file"
}

build_openvpn_args() {
  local conf="$1"

  args=(
    --config "$conf"
    --script-security 2
    --up /usr/local/bin/sockd.sh
    --down /usr/local/bin/sockd-down.sh
    --down-pre
    --up-restart
  )

  if ! has_directive "ping" "$conf"; then
    args+=( --ping "${OPENVPN_PING:-10}" )
  fi

  if ! has_directive "ping-restart" "$conf"; then
    args+=( --ping-restart "${OPENVPN_PING_RESTART:-60}" )
  fi

  if ! has_directive "connect-retry" "$conf"; then
    args+=( --connect-retry "${OPENVPN_CONNECT_RETRY_DELAY:-5}" "${OPENVPN_CONNECT_RETRY_MAX:-60}" )
  fi

  if ! has_directive "connect-timeout" "$conf"; then
    args+=( --connect-timeout "${OPENVPN_CONNECT_TIMEOUT:-30}" )
  fi

  if ! has_directive "resolv-retry" "$conf"; then
    args+=( --resolv-retry "${OPENVPN_RESOLV_RETRY:-infinite}" )
  fi

  if [ -n "${OPENVPN_EXTRA_ARGS:-}" ]; then
    # shellcheck disable=SC2206
    extra_args=( ${OPENVPN_EXTRA_ARGS} )
    args+=( "${extra_args[@]}" )
  fi
}

config_file="$(resolve_config_file)"

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
  build_openvpn_args "$config_file"
  /usr/sbin/openvpn "${args[@]}" &
  openvpn_pid=$!
  wait "$openvpn_pid"
  sleep 1
done
