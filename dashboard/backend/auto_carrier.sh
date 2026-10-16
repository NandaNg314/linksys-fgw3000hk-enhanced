#!/bin/sh
# ==============================================================================
# Linksys FGW3000 Automatic Carrier APN & 5G/4G Network Mode Auto-Adapter
# Supports: China Mobile (CMCC), China Telecom (CT), China Unicom (CU)
# ==============================================================================

LOG_FILE="/tmp/auto_carrier.log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [AUTO_CARRIER] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null
}

get_cms_val() {
    local k="$1"
    cmscfg -g -n "$k" 2>/dev/null | sed -n "s/.*$k=\(.*\)/\1/p" | tr -d '\r\n'
}

# Apply APN and Network Mode for detected carrier
apply_carrier_profile() {
    local op="$1"
    local apn="$2"
    local sa_mode="$3"

    log "Applying carrier profile: Operator=$op, APN=$apn, SA_Mode=$sa_mode"

    # Update CMS config
    cmscfg -s -n threeG_network_mode -v "2" >/dev/null 2>&1
    cmscfg -s -n threeG_network_sa_mode -v "$sa_mode" >/dev/null 2>&1
    cmscfg -s -n NR_FullBand -v "1,3,5,28,78,79" >/dev/null 2>&1
    cmscfg -s -n LTE_FullBand -v "1,3,7,8" >/dev/null 2>&1
    cmscfg -s -n NR_SupportBand -v "1,3,5,28,78,79" >/dev/null 2>&1
    cmscfg -s -n LTE_SupportBand -v "1,3,7,8" >/dev/null 2>&1
    cmscfg -s -n NR_FullBandScan -v "1" >/dev/null 2>&1
    cmscfg -s -n LTE_FullBandScan -v "1" >/dev/null 2>&1
    cmscfg -s -n APN_Rule1 -v "1,3,0,1,$apn,0" >/dev/null 2>&1

    cmscfg -w /mnt/jffs2/conf/user/multimode.conf >/dev/null 2>&1
    cmscfg -w /mnt/jffs2/conf/user/nrsetting.conf >/dev/null 2>&1
    cmscfg -w /mnt/jffs2/conf/user/ltesetting.conf >/dev/null 2>&1
    cmscfg -w /mnt/jffs2/conf/user/apn.conf >/dev/null 2>&1

    killall -SIGALRM lte_mgr 2>/dev/null
    log "Profile applied and lte_mgr signaled."
}

check_and_adapt() {
    local iccid=""
    local plmn=""

    # Try up to 5 times to read valid ICCID
    for i in 1 2 3 4 5; do
        iccid=$(get_cms_val "ICCID")
        plmn=$(get_cms_val "PLMNID")
        [ -n "$iccid" ] && [ "$iccid" != "(null)" ] && break
        sleep 2
    done

    log "Read ICCID=[$iccid], PLMN=[$plmn]"

    local detected_op=""
    local target_apn=""
    local target_sa="0"

    case "$iccid" in
        898600*|898602*|898604*|898607*|898608*)
            detected_op="CMCC"
            target_apn="cmnet"
            target_sa="0"
            ;;
        898603*|898611*)
            detected_op="CT"
            target_apn="ctnet"
            target_sa="0"
            ;;
        898601*|898606*|898609*)
            detected_op="CU"
            target_apn="3gnet"
            target_sa="0"
            ;;
        *)
            case "$plmn" in
                46000|46002|46007|46008)
                    detected_op="CMCC"
                    target_apn="cmnet"
                    target_sa="0"
                    ;;
                46003|46005|46011)
                    detected_op="CT"
                    target_apn="ctnet"
                    target_sa="0"
                    ;;
                46001|46006|46009)
                    detected_op="CU"
                    target_apn="3gnet"
                    target_sa="0"
                    ;;
                *)
                    log "Unknown SIM card or no SIM inserted."
                    return 1
                    ;;
            esac
            ;;
    esac

    local last_op_file="/tmp/last_detected_operator"
    local last_op=""
    [ -f "$last_op_file" ] && last_op=$(cat "$last_op_file")

    if [ "$last_op" != "$detected_op" ]; then
        log "Carrier changed from [$last_op] to [$detected_op]. Re-configuring..."
        echo "$detected_op" > "$last_op_file"
        apply_carrier_profile "$detected_op" "$target_apn" "$target_sa"
    fi
}

MODE="${1:-once}"

if [ "$MODE" = "once" ]; then
    check_and_adapt
elif [ "$MODE" = "daemon" ]; then
    log "Auto Carrier Daemon started in background."
    while true; do
        check_and_adapt
        sleep 20
    done
elif [ "$MODE" = "force_cmcc" ]; then
    log "Manual override: Force China Mobile profile"
    echo "CMCC" > /tmp/last_detected_operator
    apply_carrier_profile "CMCC" "cmnet" "0"
elif [ "$MODE" = "force_ct" ]; then
    log "Manual override: Force China Telecom SA profile"
    echo "CT" > /tmp/last_detected_operator
    apply_carrier_profile "CT" "ctnet" "0"
elif [ "$MODE" = "force_ct_4g" ]; then
    log "Manual override: Force China Telecom 4G fallback profile"
    echo "CT" > /tmp/last_detected_operator
    apply_carrier_profile "CT" "ctnet" "1"
elif [ "$MODE" = "force_cu" ]; then
    log "Manual override: Force China Unicom SA profile"
    echo "CU" > /tmp/last_detected_operator
    apply_carrier_profile "CU" "3gnet" "0"
fi

