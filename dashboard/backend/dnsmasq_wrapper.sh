#!/bin/sh
# ==============================================================================
# Linksys FGW3000 dnsmasq Architecture Wrapper
# Enforces loopback interface (lo) and SmartDNS (6053) + 223.5.5.5 fallback
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

# 1. Update /tmp/dnsmasq.conf keeping SmartDNS primary + 223.5.5.5 fallback
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
    echo "strict-order" >> /tmp/dnsmasq.conf
    echo "server=127.0.0.1#6053" >> /tmp/dnsmasq.conf
    echo "server=223.5.5.5" >> /tmp/dnsmasq.conf
    echo "no-resolv" >> /tmp/dnsmasq.conf
    grep -q "127.0.0.1" /tmp/etc/resolv.conf 2>/dev/null || echo "nameserver 127.0.0.1" > /tmp/etc/resolv.conf 2>/dev/null
fi

# 2. Filter out --except-interface=lo and deduplicate -i lo / --interface=lo
NEW_ARGS=""
HAS_LO=0
PREV_I=0
for a in "$@"; do
    if [ "$PREV_I" -eq 1 ]; then
        PREV_I=0
        if [ "$a" = "lo" ]; then
            if [ "$HAS_LO" -eq 1 ]; then
                continue
            fi
            HAS_LO=1
        fi
        NEW_ARGS="$NEW_ARGS -i $a"
        continue
    fi
    case "$a" in
        *--except-interface=lo*)
            ;;
        -i)
            PREV_I=1
            ;;
        --interface=lo)
            if [ "$HAS_LO" -eq 0 ]; then
                HAS_LO=1
                NEW_ARGS="$NEW_ARGS $a"
            fi
            ;;
        *)
            NEW_ARGS="$NEW_ARGS $a"
            ;;
    esac
done
[ "$PREV_I" -eq 1 ] && NEW_ARGS="$NEW_ARGS -i"

# 3. Ensure single dnsmasq.real instance with single -i lo
killall -9 dnsmasq.real dnsmasq_real 2>/dev/null
if [ "$HAS_LO" -eq 1 ]; then
    exec "$REAL_BIN" $NEW_ARGS
else
    exec "$REAL_BIN" -i lo $NEW_ARGS
fi
