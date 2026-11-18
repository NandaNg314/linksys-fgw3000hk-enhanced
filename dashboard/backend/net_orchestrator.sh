#!/bin/sh
# ==============================================================================
# Linksys FGW3000 5G/4G WAN Self-Healing Orchestrator & Black-box Logger
# Modes: --boot (wait for initial attach/IP) | --check (1-min non-blocking check)
# ==============================================================================

MODE="${1:---boot}"
LOCK_FILE="/var/run/fgw_orchestrator.lock"
STATE_FILE="/tmp/.wan_state"
MHI_DEAD_CNT_FILE="/tmp/.modem_mhi_dead_cnt"
LAST_RENEW_FILE="/tmp/.wan_last_renew"
EVENT_LOG="/mnt/jffs2/wan_events.log"
UDHCPC_PID="/var/run/udhcpc_data.pid"

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

log_event() {
    local tag="$1"
    local msg="$2"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$tag] $msg" >> "$EVENT_LOG" 2>/dev/null
    local lines
    lines=$(wc -l < "$EVENT_LOG" 2>/dev/null || echo 0)
    case "$lines" in ''|*[!0-9]*) lines=0 ;; esac
    if [ "$lines" -gt 200 ]; then
        tail -n 200 "$EVENT_LOG" > /tmp/wan_events.tmp 2>/dev/null && mv -f /tmp/wan_events.tmp "$EVENT_LOG" 2>/dev/null
    fi
}

is_proxy_enabled() {
    local cfg="/mnt/jffs2/proxy/config.json"
    [ -f "$cfg" ] && head -n 5 "$cfg" | grep -q '"enabled":[ ]*true' 2>/dev/null
}

get_v4() {
    ip -4 addr show dev rmnet_data0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1
}

get_v6() {
    ip -6 addr show dev rmnet_data0 scope global 2>/dev/null | awk '/inet6 / {print $2}' | cut -d/ -f1 | head -n 1
}

get_uptime_sec() {
    local up
    up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
    case "$up" in ''|*[!0-9]*) up=0 ;; esac
    echo "$up"
}

restore_local_resolv() {
    if [ -f /mnt/jffs2/proxy/smartdns ] && ! grep -q "127.0.0.1" /tmp/etc/resolv.conf 2>/dev/null; then
        echo "nameserver 127.0.0.1" > /tmp/etc/resolv.conf 2>/dev/null
    fi
}

# 0. Retire any legacy persistent udhcpc -b daemon on Raw-IP rmnet_data0
# Use SIGKILL + pidfile removal so default.script deconfig is NEVER triggered.
if [ -f "$UDHCPC_PID" ] || pgrep -f "udhcpc.*rmnet_data0" >/dev/null 2>&1; then
    rm -f "$UDHCPC_PID" /tmp/.udhcpc_bound_ip 2>/dev/null
    for upid in $(pgrep -f "udhcpc.*rmnet_data0" 2>/dev/null); do
        kill -9 "$upid" 2>/dev/null
    done
fi

# 1. Ensure MHI control & WAN data interfaces are UP
ip link set dev rmnet_mhi_sw0 arp off up 2>/dev/null
ip link set dev rmnet_mhi0 up 2>/dev/null
ip link set dev rmnet_data0 up 2>/dev/null

# 1.5 High-confidence SDX55 MHI silent-hang hardware recovery (--check only)
# Triggers clean cold reboot ONLY when ALL 3 hard conditions hold simultaneously:
#   (1) System uptime > 300s (5 min boot guard, prevents any reboot loop)
#   (2) 2 consecutive 1-min checks with 100% packet loss to 10.10.10.3
#   (3) Kernel dmesg has qrtr_sendmsg/wda -110 or -12, OR LCMServer.log has QCM_DMS_SERVICE_ERR / rc=-16
if [ "$MODE" = "--check" ]; then
    if ping -c 2 -W 1 10.10.10.3 >/dev/null 2>&1; then
        [ -f "$MHI_DEAD_CNT_FILE" ] && rm -f "$MHI_DEAD_CNT_FILE"
    else
        mcnt=0
        [ -f "$MHI_DEAD_CNT_FILE" ] && mcnt=$(cat "$MHI_DEAD_CNT_FILE" 2>/dev/null)
        case "$mcnt" in ''|*[!0-9]*) mcnt=0 ;; esac
        mcnt=$((mcnt + 1))
        echo "$mcnt" > "$MHI_DEAD_CNT_FILE"

        now_up=$(get_uptime_sec)
        qrtr_err=$(dmesg 2>/dev/null | grep -cE "qrtr_sendmsg.*-(110|12)|wda_set_powersave_mode_req.*-(110|12)" || true)
        case "$qrtr_err" in ''|*[!0-9]*) qrtr_err=0 ;; esac

        dms_err=0
        if [ -f /tmp/lte_mgr/LCMServer.log ]; then
            dms_err=$(grep -cE "QCM_DMS_SERVICE_ERR|rc=-16|cmd return: \[-16\]" /tmp/lte_mgr/LCMServer.log 2>/dev/null || true)
            case "$dms_err" in ''|*[!0-9]*) dms_err=0 ;; esac
        fi

        if [ "$now_up" -gt 300 ] && [ "$mcnt" -ge 2 ] && { [ "$qrtr_err" -gt 0 ] || [ "$dms_err" -gt 2 ]; }; then
            log_event "CRITICAL_HEAL" "Confirmed SDX55 MHI silent hang (10.10.10.3 dead x${mcnt} + QRTR/QMI -110/-12/-16 wedge); triggering clean system reboot (up=${now_up}s qrtr=${qrtr_err} lcm16=${dms_err})"
            sync
            umount /sbin/reboot 2>/dev/null || umount -l /sbin/reboot 2>/dev/null
            ( sleep 8; sync; /bin/busybox reboot -f ) >/dev/null 2>&1 9>&- &
            /sbin/reboot 9>&-
            exit 0
        fi
    fi
fi

# 2. Boot mode: wait up to 60s for CMServerState=5 and initial Raw-IP IPv4
if [ "$MODE" = "--boot" ]; then
    echo "=== [Linksys FGW3000 5G/4G WAN Orchestrator --boot] ==="
    for i in $(seq 1 30); do
        S=$(cmscfg -gn CMServerState 2>/dev/null | sed 's/.*=//')
        [ "$S" = "5" ] && break
        sleep 2
    done
    for i in $(seq 1 10); do
        [ -n "$(get_v4)" ] && break
        [ "$i" -eq 5 ] && mc_trigger wan_ip_renew >/dev/null 2>&1 9>&-
        sleep 2
    done
fi

CM_STATE=$(cmscfg -gn CMServerState 2>/dev/null | sed 's/.*=//')
CALL_STATE=$(cmscfg -gn threeG_connect_callstate 2>/dev/null | sed 's/.*=//')

PREV_LINE=""
[ -f "$STATE_FILE" ] && PREV_LINE=$(cat "$STATE_FILE" 2>/dev/null)
PREV_STATUS=$(echo "$PREV_LINE" | cut -d'|' -f1)
PREV_V4=$(echo "$PREV_LINE" | cut -d'|' -f2)
PREV_V6=$(echo "$PREV_LINE" | cut -d'|' -f3)

# Read lte_mgr cid=1 snapshot if present
PDN_LINE=""
[ -f /tmp/pdn_connect.log ] && PDN_LINE=$(grep '^1,' /tmp/pdn_connect.log 2>/dev/null | tail -n 1)
PDN_V4=$(echo "$PDN_LINE" | cut -d',' -f3)
PDN_GW=$(echo "$PDN_LINE" | cut -d',' -f9)

# 3. QMI Raw-IP IPv4 & default route check (NO persistent udhcpc -b, NO ping-drop deconfig!)
WAN_V4=$(get_v4)
NOW_UP=$(get_uptime_sec)
LAST_RENEW=0
[ -f "$LAST_RENEW_FILE" ] && LAST_RENEW=$(cat "$LAST_RENEW_FILE" 2>/dev/null)
case "$LAST_RENEW" in ''|*[!0-9]*) LAST_RENEW=0 ;; esac

if [ "$CM_STATE" = "5" ]; then
    if [ -n "$WAN_V4" ] && [ -n "$PDN_V4" ] && [ "$WAN_V4" != "$PDN_V4" ]; then
        log_event "RECOVERY" "rmnet_data0 IPv4 ($WAN_V4) != PdnList1 ($PDN_V4); syncing via wan_ip_renew"
        echo "$NOW_UP" > "$LAST_RENEW_FILE"
        mc_trigger wan_ip_renew >/dev/null 2>&1 9>&-
        sleep 2
        WAN_V4=$(get_v4)
    elif [ -z "$WAN_V4" ] && { [ "$MODE" = "--boot" ] || [ "$LAST_RENEW" -eq 0 ] || [ $((NOW_UP - LAST_RENEW)) -ge 120 ]; }; then
        echo "$NOW_UP" > "$LAST_RENEW_FILE"
        mc_trigger wan_ip_renew >/dev/null 2>&1 9>&-
        sleep 3
        WAN_V4=$(get_v4)
        if [ -z "$WAN_V4" ]; then
            log_event "WARN" "rmnet_data0 still has no IPv4 after wan_ip_renew; running one-shot udhcpc -n -q"
            udhcpc -i rmnet_data0 -s /usr/share/udhcpc/default.script -n -q -t 2 -T 2 >/dev/null 2>&1 9>&-
            restore_local_resolv
            WAN_V4=$(get_v4)
        fi
    fi
fi

if [ -n "$WAN_V4" ]; then
    if ! ip -4 route show default 2>/dev/null | grep -q "rmnet_data0"; then
        if [ -n "$PDN_GW" ]; then
            ip route replace default via "$PDN_GW" dev rmnet_data0 2>/dev/null || ip route replace default dev rmnet_data0 2>/dev/null
        else
            ip route replace default dev rmnet_data0 2>/dev/null
        fi
        log_event "RECOVERY" "Restored IPv4 default route on rmnet_data0 ($WAN_V4)"
    fi
fi

# 4. IPv6 & br0 prefix consistency check (no SIGALRM lte_mgr!)
WAN_V6=$(get_v6)
DEF_V6=$(ip -6 route show default 2>/dev/null | grep "rmnet_data0")

if [ -n "$WAN_V4" ] && { [ -z "$WAN_V6" ] || [ -z "$DEF_V6" ]; }; then
    if [ "$LAST_RENEW" -eq 0 ] || [ $((NOW_UP - LAST_RENEW)) -ge 300 ]; then
        echo "$NOW_UP" > "$LAST_RENEW_FILE"
        log_event "RECOVERY" "IPv6 missing or no default route (v6=${WAN_V6:-none}), triggering wan_ip_renew"
        mc_trigger wan_ip_renew >/dev/null 2>&1 9>&-
        sleep 2
        WAN_V6=$(get_v6)
        DEF_V6=$(ip -6 route show default 2>/dev/null | grep "rmnet_data0")
    fi
    if [ -n "$WAN_V6" ] && [ -z "$DEF_V6" ]; then
        ip -6 route replace default dev rmnet_data0 metric 1024 2>/dev/null
        log_event "RECOVERY" "Restored IPv6 default route on rmnet_data0 ($WAN_V6)"
    fi
fi

if [ -n "$WAN_V6" ]; then
    V6_PFX=$(echo "$WAN_V6" | awk -F: '{print tolower($1":"$2":"$3":"$4)}')
    HAS_BR0_MATCH=0
    for addr in $(ip -6 addr show dev br0 scope global 2>/dev/null | awk '/inet6 / {print $2}'); do
        apfx=$(echo "$addr" | cut -d/ -f1 | awk -F: '{print tolower($1":"$2":"$3":"$4)}')
        if [ "$apfx" = "$V6_PFX" ]; then
            HAS_BR0_MATCH=1
        else
            ip -6 addr del "$addr" dev br0 2>/dev/null
            log_event "RECOVERY" "Removed stale br0 IPv6 $addr (wan_pfx=$V6_PFX)"
        fi
    done

    if [ "$HAS_BR0_MATCH" -eq 0 ] || { [ -f /tmp/etc/radvd.conf ] && ! grep -qi "$V6_PFX" /tmp/etc/radvd.conf 2>/dev/null; }; then
        mc_trigger wan_ip_renew >/dev/null 2>&1 9>&-
        sleep 1
        if [ -f /tmp/etc/radvd.conf ]; then
            sed -i '/RDNSS/,/};/d' /tmp/etc/radvd.conf 2>/dev/null
            grep -qi "$V6_PFX" /tmp/etc/radvd.conf 2>/dev/null || \
                sed -i "s/prefix [0-9a-fA-F:]*::\/64/prefix ${V6_PFX}::\/64/g" /tmp/etc/radvd.conf 2>/dev/null
        fi
        log_event "RECOVERY" "Synced br0/radvd IPv6 prefix to $V6_PFX"
    fi

    if [ "$WAN_V6" != "$PREV_V6" ] && ! is_proxy_enabled; then
        [ -f /tmp/etc/radvd.conf ] && pgrep -f "radvd" >/dev/null 2>&1 && killall -HUP radvd 2>/dev/null 9>&-
    fi
fi

# 5. Determine overall state & write flash black-box ONLY on transition
CUR_STATUS="DOWN"
if [ -n "$WAN_V4" ] && ip -4 route show default 2>/dev/null | grep -q "rmnet_data0"; then
    CUR_STATUS="OK"
fi

CUR_LINE="${CUR_STATUS}|${WAN_V4}|${WAN_V6}"
if [ "$CUR_LINE" != "$PREV_LINE" ]; then
    echo "$CUR_LINE" > "$STATE_FILE"
    if [ -z "$PREV_LINE" ]; then
        log_event "BOOT_${CUR_STATUS}" "v4=${WAN_V4:-none} v6=${WAN_V6:-none} cm=${CM_STATE:-?} call=${CALL_STATE:-?}"
    else
        log_event "STATE_${CUR_STATUS}" "prev=${PREV_STATUS:-none}(${PREV_V4:-none}) -> v4=${WAN_V4:-none} v6=${WAN_V6:-none} cm=${CM_STATE:-?}"
    fi
fi

exit 0

