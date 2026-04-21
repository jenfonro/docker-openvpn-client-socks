# OpenVPN client + SOCKS proxy
# Usage:
# Create configuration (.ovpn), mount it in a volume
# docker run --volume=something.ovpn:/ovpn.conf:ro --device=/dev/net/tun --cap-add=NET_ADMIN
# Connect to (container):1080
# Note that the config must have embedded certs
# See `start` in same repo for more ideas

FROM alpine

COPY sockd.sh /usr/local/bin/
COPY sockd-down.sh /usr/local/bin/
COPY openvpn-entrypoint.sh /usr/local/bin/
COPY openvpn-watchdog.sh /usr/local/bin/

RUN true \
    && apk add --update-cache dante-server openvpn bash openresolv openrc curl \
    && rm -rf /var/cache/apk/* \
    && chmod a+x /usr/local/bin/sockd.sh /usr/local/bin/sockd-down.sh /usr/local/bin/openvpn-entrypoint.sh /usr/local/bin/openvpn-watchdog.sh \
    && true

COPY sockd.conf /etc/

ENTRYPOINT ["/usr/local/bin/openvpn-entrypoint.sh"]
