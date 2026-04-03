#!/bin/bash
set -e
[ -f /etc/openvpn/up.sh ] && /etc/openvpn/up.sh "$@"

if pgrep -x sockd >/dev/null 2>&1; then
  exit 0
fi

/usr/sbin/sockd -D
