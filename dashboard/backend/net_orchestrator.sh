#!/bin/sh
# ==============================================================================
# Linksys FGW3000 5G/4G WAN Self-Healing Orchestrator & Black-box Logger
# Modes: --boot (wait for initial attach/IP) | --check (1-min non-blocking check)
# ==============================================================================

MODE="${1:---boot}"
LOCK_FILE="/var/run/fgw_orchestrator.lock"
STATE_FILE="/tmp/.wan_state"
BOUND_IP_FILE="/tmp/.udhcpc_bound_ip"
FAIL_CNT_FILE="/tmp/.wan_fail_cnt"
LAST_HEAL_FILE="/tmp/.wan_last_heal"
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
    cut -d. -f1 /proc/uptime 2>/dev/null || echo 0
}

start_clean_udhcpc() {
    local old_pid=""
    [ -f "$UDHCPC_PID" ] && old_pid=$(cat "$UDHCPC_PID" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        kill "$old_pid" 2>/dev/null
        sleep 1
    fi
    killall -q udhcpc 2>/dev/null

    # Close fd 9 (9>&-) so background udhcpc never inherits the orchestrator flock!
    udhcpc -i rmnet_data0 -p "$UDHCPC_PID" -s /usr/share/udhcpc/default.script -b -t 3 -T 3 -A 20 >/dev/null 2>&1 9>&-
    sleep 2

    local post_ip
    post_ip=$(get_v4)
    if [ -z "$post_ip" ]; then
        log_event "WARN" "udhcpc did not obtain lease immediately; calling wan_ip_renew"
        mc_trigger wan_ip_renew >/dev/null 2>&1 9>&-
        sleep 2
        post_ip=$(get_v4)
    fi
    [ -n "$post_ip" ] && echo "$post_ip" > "$BOUND_IP_FILE"
    local new_pid=""
    [ -f "$UDHCPC_PID" ] && new_pid=$(cat "$UDHCPC_PID" 2>/dev/null)
    log_event "DHCP" "udhcpc daemon synced (pid=${new_pid:-none}, ip=${post_ip:-none})"
}

ensure_udhcpc() {
    local cur_ip="$1"
    local pid=""
    [ -f "$UDHCPC_PID" ] && pid=$(cat "$UDHCPC_PID" 2>/dev/null)
    local bound_ip=""
    [ -f "$BOUND_IP_FILE" ] && bound_ip=$(cat "$BOUND_IP_FILE" 2>/dev/null)

    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
        start_clean_udhcpc
        return 0
    fi

    # If lte_mgr re-activated cid=1 with a new IPv4, rebind udhcpc to the new lease
    if [ -n "$cur_ip" ] && [ -n "$bound_ip" ] && [ "$cur_ip" != "$bound_ip" ]; then
        log_event "DHCP_SYNC" "WAN IPv4 drifted ($bound_ip -> $cur_ip); rebinding udhcpc"
        start_clean_udhcpc
        return 0
    fi
}

# 1. Ensure WAN interfaces are UP
ip link set dev rmnet_mhi0 up 2>/dev/null
ip link set dev rmnet_data0 up 2>/dev/null

# 2. Boot mode: wait up to 60s for CMServerState=5 and initial IPv4
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

# 3. IPv4, PDN sync & single-instance udhcpc check
WAN_V4=$(get_v4)
if [ "$CM_STATE" = "5" ]; then
    if [ -n "$PDN_V4" ] && [ -n "$WAN_V4" ] && [ "$WAN_V4" != "$PDN_V4" ]; then
        log_event "RECOVERY" "rmnet_data0 IPv4 ($WAN_V4) != PdnList1 ($PDN_V4); syncing"
        start_clean_udhcpc
        WAN_V4=$(get_v4)
    else
        ensure_udhcpc "$WAN_V4"
        WAN_V4=$(get_v4)
    fi
fi

if [ -z "$WAN_V4" ] && [ "$CM_STATE" = "5" ]; then
    mc_trigger wan_ip_renew >/dev/null 2>&1 9>&-
    sleep 2
    WAN_V4=$(get_v4)
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

# 3.5 Data-plane stale-session guard (2 consecutive failures + 300s cooldown, zero SIGALRM)
if [ "$MODE" = "--check" ] && [ "$CM_STATE" = "5" ] && [ -n "$WAN_V4" ]; then
    if ping -I rmnet_data0 -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 || ping -I rmnet_data0 -c 1 -W 2 119.29.29.29 >/dev/null 2>&1; then
        [ -f "$FAIL_CNT_FILE" ] && rm -f "$FAIL_CNT_FILE"
    else
        fcnt=0
        [ -f "$FAIL_CNT_FILE" ] && fcnt=$(cat "$FAIL_CNT_FILE" 2>/dev/null || echo 0)
        fcnt=$((fcnt + 1))
        echo "$fcnt" > "$FAIL_CNT_FILE"
        now_up=$(get_uptime_sec)
        last_heal=0
        [ -f "$LAST_HEAL_FILE" ] && last_heal=$(cat "$LAST_HEAL_FILE" 2>/dev/null || echo 0)
        if [ "$fcnt" -ge 2 ] && [ $((now_up - last_heal)) -ge 300 ]; then
            echo "$now_up" > "$LAST_HEAL_FILE"
            rm -f "$FAIL_CNT_FILE"
            log_event "SELF_HEAL" "WAN data-plane unreachable x2 on $WAN_V4; refreshing DHCP + wan_ip_renew"
            start_clean_udhcpc
            mc_trigger wan_ip_renew >/dev/null 2>&1 9>&-
            sleep 2
            WAN_V4=$(get_v4)
        fi
    fi
fi

# 4. IPv6 & br0 prefix consistency check (no SIGALRM lte_mgr!)
WAN_V6=$(get_v6)
DEF_V6=$(ip -6 route show default 2>/dev/null | grep "rmnet_data0")

if [ -n "$WAN_V4" ] && { [ -z "$WAN_V6" ] || [ -z "$DEF_V6" ]; }; then
    log_event "RECOVERY" "IPv6 missing or no default route (v6=${WAN_V6:-none}), triggering wan_ip_renew"
    mc_trigger wan_ip_renew >/dev/null 2>&1 9>&-
    sleep 2
    WAN_V6=$(get_v6)
    DEF_V6=$(ip -6 route show default 2>/dev/null | grep "rmnet_data0")
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
    [ -n "$WAN_V4" ] && echo "$WAN_V4" > "$BOUND_IP_FILE"
    if [ -z "$PREV_LINE" ]; then
        log_event "BOOT_${CUR_STATUS}" "v4=${WAN_V4:-none} v6=${WAN_V6:-none} cm=${CM_STATE:-?} call=${CALL_STATE:-?}"
    else
        log_event "STATE_${CUR_STATUS}" "prev=${PREV_STATUS:-none}(${PREV_V4:-none}) -> v4=${WAN_V4:-none} v6=${WAN_V6:-none} cm=${CM_STATE:-?}"
    fi
fi

exit 0
