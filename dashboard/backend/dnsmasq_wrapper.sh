#!/bin/sh
# ==============================================================================
# Linksys FGW3000 dnsmasq Architecture Wrapper
# Enforces loopback interface (lo) and SmartDNS (6053) convergence
# ==============================================================================

REAL_BIN="/tmp/dnsmasq.real"

# Ensure REAL_BIN exists and is executable
if [ ! -x "$REAL_BIN" ]; then
    if [ -f /mnt/jffs2/proxy/dnsmasq_real ]; then
        REAL_BIN="/mnt/jffs2/proxy/dnsmasq_real"
    else
        umount -l /usr/sbin/dnsmasq 2>/dev/null
        exec /usr/sbin/dnsmasq "$@"
    fi
fi

# 1. Update /tmp/dnsmasq.conf with SmartDNS upstream and fallback before starting
if [ -f /tmp/dnsmasq.conf ]; then
    ad_conf="/mnt/jffs2/proxy/adblock_dnsmasq.conf"
    if [ -f "$ad_conf" ] && ! grep -q "conf-file=$ad_conf" /tmp/dnsmasq.conf; then
        echo "conf-file=$ad_conf" >> /tmp/dnsmasq.conf
    fi
    sed -i '/127.0.0.1#6053/d' /tmp/dnsmasq.conf 2>/dev/null
    sed -i '/192.168.15.1#6053/d' /tmp/dnsmasq.conf 2>/dev/null
    sed -i '/223.5.5.5/d' /tmp/dnsmasq.conf 2>/dev/null
    sed -i '/strict-order/d' /tmp/dnsmasq.conf 2>/dev/null
    sed -i '/no-resolv/d' /tmp/dnsmasq.conf 2>/dev/null
    echo "server=127.0.0.1#6053" >> /tmp/dnsmasq.conf
    echo "no-resolv" >> /tmp/dnsmasq.conf
    echo "nameserver 127.0.0.1" > /tmp/etc/resolv.conf 2>/dev/null
fi

# 2. Filter out arguments that break loopback DNS resolution
NEW_ARGS=""
for a in "$@"; do
    case "$a" in
        *--except-interface=lo*)
            ;;
        *)
            NEW_ARGS="$NEW_ARGS $a"
            ;;
    esac
done

# 3. Always include -i lo
exec "$REAL_BIN" -i lo $NEW_ARGS
