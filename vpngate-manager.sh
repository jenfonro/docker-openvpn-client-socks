#!/bin/bash
set -euo pipefail

VP_ROOT="${VP_ROOT:-/opt/server/vpngate}"
TARGET_COUNTRY="${TARGET_COUNTRY:-}"
VPNGATE_CSV_URL="${VPNGATE_CSV_URL:-http://www.vpngate.net/api/iphone/}"
OPENVPN_RUNTIME_CONF="${OPENVPN_RUNTIME_CONF:-/tmp/openvpn-client.conf}"

WATCHDOG_TIMEOUT="${WATCHDOG_TIMEOUT:-15}"
WATCHDOG_TEST_URL="${WATCHDOG_TEST_URL:-https://api.ipify.org}"
WATCHDOG_DIRECT_TEST_URL="${WATCHDOG_DIRECT_TEST_URL:-$WATCHDOG_TEST_URL}"
WATCHDOG_REQUIRE_DIFFERENT_IP="${WATCHDOG_REQUIRE_DIFFERENT_IP:-1}"
WATCHDOG_REQUIRE_TUN_ROUTE="${WATCHDOG_REQUIRE_TUN_ROUTE:-1}"
WATCHDOG_PROXY_URL="${WATCHDOG_PROXY_URL:-}"

ROTATE_WAIT_START_SECONDS="${ROTATE_WAIT_START_SECONDS:-8}"
ROTATE_CONNECT_RETRIES="${ROTATE_CONNECT_RETRIES:-6}"
ROTATE_CONNECT_INTERVAL="${ROTATE_CONNECT_INTERVAL:-5}"
REFRESH_TIMEOUT="${REFRESH_TIMEOUT:-90}"

log() {
  printf '[%(%F %T)T] %s\n' -1 "$*"
}

require_country() {
  if [ -z "$TARGET_COUNTRY" ]; then
    echo "TARGET_COUNTRY is required for this action" >&2
    return 1
  fi
}

config_root() {
  echo "$VP_ROOT/config"
}

used_root() {
  echo "$VP_ROOT/used"
}

ban_root() {
  echo "$VP_ROOT/ban"
}

country_config_dir() {
  echo "$(config_root)/$TARGET_COUNTRY"
}

country_ok_dir() {
  echo "$(used_root)/$TARGET_COUNTRY/ok"
}

country_error_dir() {
  echo "$(used_root)/$TARGET_COUNTRY/error"
}

ensure_dirs() {
  mkdir -p "$(config_root)" "$(used_root)" "$(ban_root)"
  if [ -n "$TARGET_COUNTRY" ]; then
    mkdir -p "$(country_config_dir)" "$(country_ok_dir)" "$(country_error_dir)"
  fi
}

sanitize_country() {
  local value="$1"
  value="${value//[^0-9A-Za-z]/_}"
  value="$(echo "$value" | sed -E 's/_+/_/g; s/^_+//; s/_+$//')"
  [ -n "$value" ] || value="Unknown"
  echo "$value"
}

sanitize_ip() {
  local value="$1"
  value="${value//[^0-9A-Za-z_.-]/_}"
  echo "${value:0:64}"
}

get_default_proxy_url() {
  local eth0_ip
  eth0_ip="$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | head -n1)"
  if [ -n "$eth0_ip" ]; then
    echo "socks5://${eth0_ip}:1080"
  else
    echo "socks5://127.0.0.1:1080"
  fi
}

proxy_url() {
  if [ -n "$WATCHDOG_PROXY_URL" ]; then
    echo "$WATCHDOG_PROXY_URL"
  else
    get_default_proxy_url
  fi
}

trim_output() {
  tr -d '\r\n[:space:]'
}

probe_proxy_ip() {
  curl -sS --max-time "$WATCHDOG_TIMEOUT" --proxy "$(proxy_url)" "$WATCHDOG_TEST_URL" 2>/dev/null | trim_output
}

probe_direct_ip() {
  env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
    curl -sS --max-time "$WATCHDOG_TIMEOUT" --interface eth0 "$WATCHDOG_DIRECT_TEST_URL" 2>/dev/null | trim_output
}

health_check() {
  local p_ip d_ip

  p_ip="$(probe_proxy_ip)" || return 1
  [ -n "$p_ip" ] || return 1

  if [ "$WATCHDOG_REQUIRE_TUN_ROUTE" = "1" ]; then
    ip route get 1.1.1.1 2>/dev/null | grep -q 'dev tun' || return 1
  fi

  if [ "$WATCHDOG_REQUIRE_DIFFERENT_IP" = "1" ]; then
    d_ip="$(probe_direct_ip)" || return 1
    [ -n "$d_ip" ] || return 1
    [ "$p_ip" != "$d_ip" ] || return 1
  fi

  return 0
}

openvpn_running() {
  pgrep -f '^/usr/sbin/openvpn( |$)' >/dev/null 2>&1
}

stop_openvpn() {
  pkill -TERM -f '^/usr/sbin/openvpn( |$)' >/dev/null 2>&1 || true
}

restart_openvpn_process() {
  stop_openvpn
}

wait_openvpn_started() {
  local retries=20
  local i
  for ((i=1; i<=retries; i++)); do
    if openvpn_running; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_healthy_after_switch() {
  local i

  sleep "$ROTATE_WAIT_START_SECONDS"

  for ((i=1; i<=ROTATE_CONNECT_RETRIES; i++)); do
    if health_check; then
      probe_proxy_ip || true
      return 0
    fi
    sleep "$ROTATE_CONNECT_INTERVAL"
  done

  return 1
}

ensure_openvpn_compat() {
  local conf="$1"
  [ -f "$conf" ] || return 0

  if ! grep -q '^data-ciphers ' "$conf"; then
    printf '%s\n' 'data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-128-CBC' >> "$conf"
  fi
  if ! grep -q '^data-ciphers-fallback ' "$conf"; then
    printf '%s\n' 'data-ciphers-fallback AES-128-CBC' >> "$conf"
  fi
  if ! grep -q '^cipher ' "$conf"; then
    printf '%s\n' 'cipher AES-128-CBC' >> "$conf"
  fi
}

stage_candidate() {
  local candidate="$1"
  cp -f "$candidate" "$OPENVPN_RUNTIME_CONF"
  chmod 600 "$OPENVPN_RUNTIME_CONF"
  ensure_openvpn_compat "$OPENVPN_RUNTIME_CONF"
}

strip_ok_suffix() {
  local stem="$1"
  stem="${stem%.ovpn}"
  if [[ "$stem" =~ ^(.+)_ok_[0-9]+$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "$stem"
  fi
}

build_ok_filename() {
  local source="$1"
  local base stem
  base="$(basename "$source")"
  stem="$(strip_ok_suffix "$base")"
  echo "${stem}_ok_$(date +%s).ovpn"
}

unique_path() {
  local path="$1"
  local stem ext n

  if [ ! -e "$path" ]; then
    echo "$path"
    return 0
  fi

  ext="${path##*.}"
  stem="${path%.*}"
  n=1
  while [ -e "${stem}_${n}.${ext}" ]; do
    n=$((n + 1))
  done
  echo "${stem}_${n}.${ext}"
}

mark_ok_timestamp() {
  local src="$1"
  local dst
  dst="$(country_ok_dir)/$(build_ok_filename "$src")"
  dst="$(unique_path "$dst")"

  if [ "$src" != "$dst" ]; then
    mv -f "$src" "$dst"
  fi

  echo "$dst"
}

move_to_ok() {
  local src="$1"
  local dst
  dst="$(country_ok_dir)/$(build_ok_filename "$src")"
  dst="$(unique_path "$dst")"
  mv -f "$src" "$dst"
  echo "$dst"
}

move_to_error() {
  local src="$1"
  local dst
  dst="$(country_error_dir)/$(basename "$src")"
  dst="$(unique_path "$dst")"
  mv -f "$src" "$dst"
  echo "$dst"
}

extract_hash_from_name() {
  local base="$1"
  base="$(basename "$base")"
  if [[ "$base" =~ _([0-9a-fA-F]{8,64})(_ok_[0-9]+|_[0-9]+)?\.ovpn$ ]]; then
    echo "${BASH_REMATCH[1],,}"
    return 0
  fi
  return 1
}

hash_exists() {
  local hash="$1"
  local file parsed

  [ -n "$hash" ] || return 1

  while IFS= read -r file; do
    parsed="$(extract_hash_from_name "$file" || true)"
    if [ -n "$parsed" ] && [ "$parsed" = "$hash" ]; then
      return 0
    fi
  done < <(find "$(config_root)" "$(used_root)" "$(ban_root)" -type f -name '*.ovpn' 2>/dev/null)

  return 1
}

refresh_pool() {
  local csv_file rows_file
  local added=0 skipped=0 total=0

  ensure_dirs

  csv_file="$(mktemp)"
  rows_file="$(mktemp)"
  trap 'rm -f "$csv_file" "$rows_file"' RETURN

  log "Refreshing VPNGate pool from upstream..."

  if ! env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY \
      curl -fsSL --interface eth0 --connect-timeout 10 --max-time "$REFRESH_TIMEOUT" "$VPNGATE_CSV_URL" | tr -d '\r' > "$csv_file"; then
    log "Refresh failed: unable to fetch VPNGate CSV"
    return 1
  fi

  awk -F, '
    BEGIN{OFS=","}
    /^\*/ {next}
    !header && /OpenVPN_ConfigData_Base64/ {
      for (i=1;i<=NF;i++){
        if ($i=="OpenVPN_ConfigData_Base64") b64i=i
        if ($i=="IP") ipi=i
        if ($i=="CountryLong") cli=i
      }
      header=1
      next
    }
    header && b64i>0 && $b64i!="" {
      print $ipi,$b64i,$cli
    }
  ' "$csv_file" > "$rows_file"

  while IFS=',' read -r ip b64 country; do
    local scountry sip hash dir file tmp

    [ -n "$b64" ] || continue
    total=$((total + 1))

    scountry="$(sanitize_country "$country")"
    sip="$(sanitize_ip "$ip")"

    if command -v md5sum >/dev/null 2>&1; then
      hash="$(printf '%s' "$b64" | md5sum | awk '{print substr($1,1,8)}')"
    else
      hash="$(printf '%s' "$b64" | cksum | awk '{print substr($1,1,8)}')"
    fi
    hash="${hash,,}"

    if hash_exists "$hash"; then
      skipped=$((skipped + 1))
      continue
    fi

    dir="$(config_root)/$scountry"
    mkdir -p "$dir"
    file="$dir/${scountry}_${sip}_${hash}.ovpn"
    tmp="${file}.tmp"

    if printf '%s' "$b64" | base64 -d > "$tmp" 2>/dev/null; then
      ensure_openvpn_compat "$tmp"
      mv -f "$tmp" "$file"
      added=$((added + 1))
    else
      rm -f "$tmp"
      skipped=$((skipped + 1))
    fi
  done < "$rows_file"

  log "Refresh complete: added=${added}, skipped=${skipped}, parsed=${total}"
  trap - RETURN
  rm -f "$csv_file" "$rows_file"
  return 0
}

read_pool_lists() {
  mapfile -t OK_LIST < <(find "$(country_ok_dir)" -maxdepth 1 -type f -name '*.ovpn' 2>/dev/null | sort)
  mapfile -t CFG_LIST < <(find "$(country_config_dir)" -maxdepth 1 -type f -name '*.ovpn' 2>/dev/null | sort)
}

config_pool_empty() {
  local n
  n="$(find "$(country_config_dir)" -maxdepth 1 -type f -name '*.ovpn' | wc -l)"
  [ "$n" -eq 0 ]
}

prepare_runtime_conf() {
  require_country
  ensure_dirs

  if [ -s "$OPENVPN_RUNTIME_CONF" ]; then
    return 0
  fi

  read_pool_lists
  if [ "${#OK_LIST[@]}" -gt 0 ]; then
    stage_candidate "${OK_LIST[0]}"
    return 0
  fi

  if [ "${#CFG_LIST[@]}" -eq 0 ]; then
    stop_openvpn
    refresh_pool || true
    read_pool_lists
  fi

  if [ "${#CFG_LIST[@]}" -gt 0 ]; then
    stage_candidate "${CFG_LIST[0]}"
    return 0
  fi

  return 1
}

rotate_country() {
  require_country
  ensure_dirs

  local refreshed=0
  local proxy_ip

  while true; do
    read_pool_lists

    if [ "${#OK_LIST[@]}" -eq 0 ] && [ "${#CFG_LIST[@]}" -eq 0 ]; then
      if [ "$refreshed" -eq 0 ]; then
        log "No configs for [$TARGET_COUNTRY], refreshing pool..."
        stop_openvpn
        refresh_pool || true
        refreshed=1
        continue
      fi
      log "Rotation failed: no available configs for [$TARGET_COUNTRY]"
      return 1
    fi

    local total=$(( ${#OK_LIST[@]} + ${#CFG_LIST[@]} ))
    local idx=0
    local file moved

    for file in "${OK_LIST[@]}"; do
      idx=$((idx + 1))
      log "Switching to [$TARGET_COUNTRY] [${idx}/${total}] (used/ok): $(basename "$file")"

      stage_candidate "$file"
      restart_openvpn_process
      wait_openvpn_started || true

      if proxy_ip="$(wait_healthy_after_switch || true)" && [ -n "$proxy_ip" ]; then
        moved="$(mark_ok_timestamp "$file")"
        log "Connectivity OK after rotation: ${proxy_ip} (config: $(basename "$moved"))"
        return 0
      fi

      log "Candidate failed (kept in ok): $(basename "$file")"
    done

    for file in "${CFG_LIST[@]}"; do
      idx=$((idx + 1))
      log "Switching to [$TARGET_COUNTRY] [${idx}/${total}] (config): $(basename "$file")"

      stage_candidate "$file"
      restart_openvpn_process
      wait_openvpn_started || true

      if proxy_ip="$(wait_healthy_after_switch || true)" && [ -n "$proxy_ip" ]; then
        moved="$(move_to_ok "$file")"
        log "Connectivity OK after rotation: ${proxy_ip} (config: $(basename "$moved"))"
        return 0
      fi

      moved="$(move_to_error "$file")"
      log "Candidate failed, moved to error: $(basename "$moved")"
    done

    if [ "$refreshed" -eq 0 ] && config_pool_empty; then
      log "Config pool exhausted for [$TARGET_COUNTRY], refreshing pool..."
      stop_openvpn
      refresh_pool || true
      refreshed=1
      continue
    fi

    log "Rotation failed: all candidates failed for [$TARGET_COUNTRY]"
    return 1
  done
}

usage() {
  cat <<USAGE
Usage: vpngate-manager.sh <command>

Commands:
  init      Create required directories
  refresh   Fetch VPNGate and save deduplicated configs under config/<country>
  prepare   Ensure runtime config exists for TARGET_COUNTRY
  rotate    Rotate configs for TARGET_COUNTRY until a healthy connection is found
  health    Run watchdog health check
  proxy-ip  Print current proxy egress IP
USAGE
}

main() {
  local cmd="${1:-}"

  case "$cmd" in
    init)
      ensure_dirs
      ;;
    refresh)
      refresh_pool
      ;;
    prepare)
      prepare_runtime_conf
      ;;
    rotate)
      rotate_country
      ;;
    health)
      health_check
      ;;
    proxy-ip)
      probe_proxy_ip
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
