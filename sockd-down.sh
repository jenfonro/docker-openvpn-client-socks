#!/bin/bash
set -e

[ -f /etc/openvpn/down.sh ] && /etc/openvpn/down.sh "$@"

# Ensure the SOCKS proxy follows the lifecycle of tun0.
pkill -x sockd >/dev/null 2>&1 || true
