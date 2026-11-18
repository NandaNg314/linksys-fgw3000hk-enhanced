#!/bin/sh
# Linksys FGW3000-HK Backend API Handler (Cellular, Band Lock & Transparent Proxy)

echo "Content-Type: application/json; charset=utf-8"
echo "Access-Control-Allow-Origin: *"
echo "Access-Control-Allow-Methods: GET, POST, OPTIONS"
echo "Access-Control-Allow-Headers: Content-Type"
echo ""

if [ "$REQUEST_METHOD" = "OPTIONS" ]; then
    exit 0
fi

QS="$QUERY_STRING"
get_query_param() {
    echo "$QS" | grep -o -E "(^|&)$1=[^&]*" | sed -e 's/^&//' -e "s/^$1=//"
}

ACTION=$(get_query_param "action")

read_post_data() {
    if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
        head -c "$CONTENT_LENGTH"
    else
        cat
    fi
}

# Helper to read cmscfg value cleanly
get_cms_val() {
    local key="$1"
    local raw
    raw=$(cmscfg -g -n "$key" 2>/dev/null)
    echo "$raw" | sed -n "s/.*$key=\(.*\)/\1/p" | tr -d '\r\n'
}

# 1. Action: get_cellular
if [ "$ACTION" = "get_cellular" ]; then
    band=$(get_cms_val "BAND")
    nr_band=$(get_cms_val "NR_Band")
    nr_rsrp=$(get_cms_val "NR_RSRP")
    nr_snr=$(get_cms_val "NR_SNR")
    nr_pcid=$(get_cms_val "NR_PCID")
    lte_rsrp=$(get_cms_val "lte_status_rsrp")
    lte_sinr=$(get_cms_val "lte_status_sinr")
    eci=$(get_cms_val "ECI")
    real_cell_id=$(get_cms_val "RealCellID")
    enodeb_id=$(get_cms_val "eNodeBID")
    tac=$(get_cms_val "TAC")
    plmnid=$(get_cms_val "PLMNID")
    rrc_state=$(get_cms_val "RRC_STATE")
    net_mode=$(get_cms_val "threeG_network_mode")
    lte_full_band=$(get_cms_val "LTE_FullBand")
    nr_full_band=$(get_cms_val "NR_FullBand")

    [ -z "$band" ] && band="N/A"
    [ -z "$nr_band" ] && nr_band="N/A"
    [ -z "$nr_rsrp" ] && nr_rsrp="N/A"
    [ -z "$nr_snr" ] && nr_snr="N/A"
    [ -z "$nr_pcid" ] && nr_pcid="N/A"
    [ -z "$lte_rsrp" ] && lte_rsrp="N/A"
    [ -z "$lte_sinr" ] && lte_sinr="N/A"
    [ -z "$eci" ] && eci="N/A"
    [ -z "$real_cell_id" ] && real_cell_id="N/A"
    [ -z "$enodeb_id" ] && enodeb_id="N/A"
    [ -z "$tac" ] && tac="N/A"
    [ -z "$plmnid" ] && plmnid="N/A"
    [ -z "$rrc_state" ] && rrc_state="N/A"
    [ -z "$net_mode" ] && net_mode="2"
    [ -z "$lte_full_band" ] && lte_full_band="1,3,7,8"
    [ -z "$nr_full_band" ] && nr_full_band="1,3,5,28,78,79"

    sa_mode=$(get_cms_val "threeG_network_sa_mode")
    apn_rule=$(get_cms_val "APN_Rule1")
    apn_name=$(echo "$apn_rule" | cut -d',' -f5)
    [ -z "$apn_name" ] && apn_name="auto"
    [ -z "$sa_mode" ] && sa_mode="0"

    nr_bw_raw=$(get_cms_val "NR_Bandwidth")
    [ -z "$nr_bw_raw" ] && nr_bw_raw="0"
    case "$nr_bw_raw" in *[0-9]*) nr_bw_mhz=$((nr_bw_raw / 1000)) ;; *) nr_bw_mhz="0" ;; esac

    cpu_temp=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "0")
    modem_raw=$(cat /sys/class/thermal/thermal_zone12/temp 2>/dev/null || echo "0")
    modem_temp=$(awk -v r="$modem_raw" 'BEGIN{if(r>100){printf "%.1f", r/10}else{print r}}')
    load_avg=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "0.0 0.0 0.0")
    mem_stat=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "%d,%d,%d", int((t-a)/1024), int(t/1024), int((t-a)*100/t)}' /proc/meminfo 2>/dev/null || echo "0,0,0")
    mem_used=$(echo "$mem_stat" | cut -d',' -f1)
    mem_total=$(echo "$mem_stat" | cut -d',' -f2)
    mem_pct=$(echo "$mem_stat" | cut -d',' -f3)
    traffic=$(awk '/rmnet_data0:/{printf "%.1f,%.1f", $2/1048576, $10/1048576}' /proc/net/dev 2>/dev/null || echo "0,0")
    wan_rx=$(echo "$traffic" | cut -d',' -f1)
    wan_tx=$(echo "$traffic" | cut -d',' -f2)
    uptime_sec=$(cut -d'.' -f1 /proc/uptime 2>/dev/null || echo "0")

    smartdns_running="false"
    pgrep -f "smartdns.*smartdns.conf" >/dev/null 2>&1 && smartdns_running="true"
    rule_count=0
    [ -f /tmp/anti-ad-for-smartdns.conf ] && rule_count=$(wc -l < /tmp/anti-ad-for-smartdns.conf 2>/dev/null | tr -d ' ')

    modem_json=$(curl -s --connect-timeout 1 -m 4 "http://10.10.10.3:55102/cgi-bin/cell_qos" 2>/dev/null)
    if echo "$modem_json" | grep -q '"ok":true'; then
        printf '%s\n' "$modem_json" > /tmp/.ap_cell_qos.cache 2>/dev/null
    elif [ -f /tmp/.ap_cell_qos.cache ]; then
        modem_json=$(cat /tmp/.ap_cell_qos.cache 2>/dev/null)
    fi
    jget() {
        echo "$modem_json" | sed -n "s/.*\"$1\":\(\"[^\"]*\"\|[^,}]*\).*/\1/p" | head -n 1
    }
    qci_val="null"; qos_label_json="\"N/A\""
    ambr_dl_val="null"; ambr_ul_val="null"; ambr_dl_mbps="null"; ambr_ul_mbps="null"
    ambr_avail="false"; ambr_reason_json="\"unavailable\""; ambr_hex_json="null"; ambr_src_json="null"
    nr_bwp_val="null"; nr_rank_val="null"; nr_cqi_val="null"; nr_rsrq_val="null"; nr_ssb_val="null"
    ims_run="false"; ims_reg="false"; ims_state_json="\"UNKNOWN\""; ims_ip_json="null"; ims_pcscf_json="null"
    if echo "$modem_json" | grep -q '"ok":true'; then
        v=$(jget "qci"); [ -n "$v" ] && qci_val="$v"
        v=$(jget "qos_label"); [ -n "$v" ] && qos_label_json="$v"
        v=$(jget "ambr_dl_kbps"); [ -n "$v" ] && ambr_dl_val="$v"
        v=$(jget "ambr_ul_kbps"); [ -n "$v" ] && ambr_ul_val="$v"
        v=$(jget "ambr_available"); [ -n "$v" ] && ambr_avail="$v"
        v=$(jget "ambr_reason"); [ -n "$v" ] && ambr_reason_json="$v"
        v=$(jget "ambr_dl_mbps"); [ -n "$v" ] && ambr_dl_mbps="$v"
        v=$(jget "ambr_ul_mbps"); [ -n "$v" ] && ambr_ul_mbps="$v"
        v=$(jget "ambr_raw_hex"); [ -n "$v" ] && ambr_hex_json="$v"
        v=$(jget "ambr_source"); [ -n "$v" ] && ambr_src_json="$v"
        v=$(jget "nr_bw_mhz"); [ -n "$v" ] && nr_bwp_val="$v"
        v=$(jget "nr_rank"); [ -n "$v" ] && nr_rank_val="$v"
        v=$(jget "nr_cqi"); [ -n "$v" ] && nr_cqi_val="$v"
        v=$(jget "nr_rsrq"); [ -n "$v" ] && nr_rsrq_val="$v"
        v=$(jget "nr_ssb"); [ -n "$v" ] && nr_ssb_val="$v"
        v=$(jget "running"); [ -n "$v" ] && ims_run="$v"
        v=$(jget "registered"); [ -n "$v" ] && ims_reg="$v"
        v=$(jget "state"); [ -n "$v" ] && ims_state_json="$v"
        v=$(jget "ip"); [ -n "$v" ] && ims_ip_json="$v"
        v=$(jget "pcscf"); [ -n "$v" ] && ims_pcscf_json="$v"
        if [ "$nr_bw_mhz" = "0" ] && [ "$nr_bwp_val" != "null" ]; then nr_bw_mhz="$nr_bwp_val"; fi
    fi

    cat <<EOF
{
  "success": true,
  "cellular": {
    "band": "$band",
    "nr_band": "$nr_band",
    "nr_rsrp": "$nr_rsrp",
    "nr_snr": "$nr_snr",
    "nr_pcid": "$nr_pcid",
    "nr_bandwidth": "$nr_bw_mhz",
    "lte_rsrp": "$lte_rsrp",
    "lte_sinr": "$lte_sinr",
    "eci": "$eci",
    "real_cell_id": "$real_cell_id",
    "enodeb_id": "$enodeb_id",
    "tac": "$tac",
    "plmnid": "$plmnid",
    "rrc_state": "$rrc_state",
    "net_mode": "$net_mode",
    "sa_mode": "$sa_mode",
    "apn": "$apn_name",
    "lte_full_band": "$lte_full_band",
    "nr_full_band": "$nr_full_band",
    "qci": $qci_val,
    "qos_label": $qos_label_json,
    "ambr_dl_kbps": $ambr_dl_val,
    "ambr_ul_kbps": $ambr_ul_val,
    "ambr_available": $ambr_avail,
    "ambr_reason": $ambr_reason_json,
    "ambr_dl_mbps": $ambr_dl_mbps,
    "ambr_ul_mbps": $ambr_ul_mbps,
    "ambr_raw_hex": $ambr_hex_json,
    "ambr_source": $ambr_src_json,
    "nr_bwp_mhz": $nr_bwp_val,
    "nr_rank": $nr_rank_val,
    "nr_cqi": $nr_cqi_val,
    "nr_rsrq": $nr_rsrq_val,
    "nr_ssb": $nr_ssb_val
  },
  "ims": {
    "running": $ims_run,
    "registered": $ims_reg,
    "state": $ims_state_json,
    "ip": $ims_ip_json,
    "pcscf": $ims_pcscf_json
  },
  "system": {
    "cpu_temp": "$cpu_temp",
    "modem_temp": "$modem_temp",
    "load_avg": "$load_avg",
    "mem_used": "$mem_used",
    "mem_total": "$mem_total",
    "mem_pct": "$mem_pct",
    "wan_rx_mb": "$wan_rx",
    "wan_tx_mb": "$wan_tx",
    "uptime_sec": "$uptime_sec",
    "smartdns_active": $smartdns_running,
    "smartdns_rules": $rule_count
  }
}
EOF
    exit 0
fi

# 1.5 Action: set_carrier (Manual force carrier APN & mode)
if [ "$ACTION" = "set_carrier" ]; then
    op=$(get_query_param "op")
    if [ "$op" = "cmcc" ]; then
        /mnt/jffs2/auto_carrier.sh force_cmcc >/dev/null 2>&1 &
    elif [ "$op" = "ct" ]; then
        /mnt/jffs2/auto_carrier.sh force_ct >/dev/null 2>&1 &
    elif [ "$op" = "ct_4g" ]; then
        /mnt/jffs2/auto_carrier.sh force_ct_4g >/dev/null 2>&1 &
    elif [ "$op" = "cu" ]; then
        /mnt/jffs2/auto_carrier.sh force_cu >/dev/null 2>&1 &
    fi
    echo '{"success":true,"message":"Carrier profile applied"}'
    exit 0
fi

# 2. Action: set_bands
if [ "$ACTION" = "set_bands" ]; then
    POST_DATA=$(read_post_data)
    mode=$(echo "$POST_DATA" | grep -o -E '(^|&)mode=[^&]*' | sed -e 's/^&//' -e 's/^mode=//')
    lte_bands=$(echo "$POST_DATA" | grep -o -E '(^|&)lte_bands=[^&]*' | sed -e 's/^&//' -e 's/^lte_bands=//')
    nr_bands=$(echo "$POST_DATA" | grep -o -E '(^|&)nr_bands=[^&]*' | sed -e 's/^&//' -e 's/^nr_bands=//')

    if [ -z "$mode" ]; then
        mode=$(echo "$POST_DATA" | sed -n 's/.*"mode":[ ]*"\([^"]*\)".*/\1/p')
        lte_bands=$(echo "$POST_DATA" | sed -n 's/.*"lte_bands":[ ]*"\([^"]*\)".*/\1/p')
        nr_bands=$(echo "$POST_DATA" | sed -n 's/.*"nr_bands":[ ]*"\([^"]*\)".*/\1/p')
    fi

    lte_bands=$(echo "$lte_bands" | sed 's/%2[cC]/,/g')
    nr_bands=$(echo "$nr_bands" | sed 's/%2[cC]/,/g')
    mode=$(echo "$mode" | sed 's/%2[cC]/,/g')

    [ -z "$mode" ] && mode="2"
    [ -z "$lte_bands" ] && lte_bands="1,3,7,8"
    [ -z "$nr_bands" ] && nr_bands="1,3,5,28,78,79"

    cmscfg -s -n threeG_network_mode -v "$mode" >/dev/null 2>&1
    cmscfg -s -n threeG_network_sa_mode -v "0" >/dev/null 2>&1
    cmscfg -s -n LTE_FullBand -v "$lte_bands" >/dev/null 2>&1
    cmscfg -s -n NR_FullBand -v "$nr_bands" >/dev/null 2>&1
    cmscfg -w /mnt/jffs2/conf/user/multimode.conf >/dev/null 2>&1
    cmscfg -w /mnt/jffs2/conf/user/ltesetting.conf >/dev/null 2>&1
    cmscfg -w /mnt/jffs2/conf/user/nrsetting.conf >/dev/null 2>&1
    killall -SIGALRM lte_mgr 2>/dev/null

    cat <<EOF
{
  "success": true,
  "message": "Band settings applied successfully",
  "applied": {
    "mode": "$mode",
    "lte_bands": "$lte_bands",
    "nr_bands": "$nr_bands"
  }
}
EOF
    exit 0
fi

# 3. Action: proxy_status
if [ "$ACTION" = "proxy_status" ]; then
    is_running=false
    cfg_file="/mnt/jffs2/proxy/config.json"
    if [ -f "$cfg_file" ] && head -n 5 "$cfg_file" | grep -q '"enabled":[ ]*true' 2>/dev/null; then
        if pgrep -f "sing-box run" >/dev/null 2>&1; then
            is_running=true
        fi
    fi

    cfg_file="/mnt/jffs2/proxy/config.json"
    if [ ! -f "$cfg_file" ]; then
        mkdir -p /mnt/jffs2/proxy
        cat << 'EOF' > "$cfg_file"
{
  "enabled": false,
  "active_node": "",
  "route_mode": "bypass_cn",
  "subscriptions": [],
  "nodes": [],
  "custom_rules": {
    "direct_domains": ["baidu.com", "bilibili.com", "qq.com", "163.com", "taobao.com", "jd.com"],
    "proxy_domains": ["google.com", "youtube.com", "github.com", "telegram.org", "twitter.com", "x.com", "openai.com"],
    "direct_ips": ["223.5.5.5", "119.29.29.29", "114.114.114.114"],
    "proxy_ips": []
  }
}
EOF
    fi

    echo "{\"success\":true,\"running\":$is_running,\"config\":"
    cat "$cfg_file"
    echo "}"
    exit 0
fi

apply_transparent_proxy() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    killall radvd 2>/dev/null

    # 1. MTU & TCP MSS Clamping to prevent cellular MTU black holes & timeouts
    ifconfig tun0 mtu 1400 2>/dev/null
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    # 2. Block IPv6 bypass & leaks
    ip6tables -D FORWARD -i br0 -o rmnet_data0 -j DROP 2>/dev/null
    ip6tables -I FORWARD 1 -i br0 -o rmnet_data0 -j DROP
    ip6tables -D FORWARD -p udp --dport 53 -j DROP 2>/dev/null
    ip6tables -I FORWARD 1 -p udp --dport 53 -j DROP
    ip6tables -D FORWARD -p tcp --dport 53 -j DROP 2>/dev/null
    ip6tables -I FORWARD 1 -p tcp --dport 53 -j DROP
    ip6tables -D INPUT -i br0 -p udp --dport 53 -j DROP 2>/dev/null
    ip6tables -I INPUT 1 -i br0 -p udp --dport 53 -j DROP
    ip6tables -D INPUT -i br0 -p tcp --dport 53 -j DROP 2>/dev/null
    ip6tables -I INPUT 1 -i br0 -p tcp --dport 53 -j DROP

    # 3. Policy routing for LAN -> tun0
    ip route replace default dev tun0 table 2022 2>/dev/null
    ip rule del priority 7998 2>/dev/null
    ip rule del priority 8000 2>/dev/null
    ip rule add to 192.168.15.0/24 lookup main priority 7998
    ip rule add iif br0 lookup 2022 priority 8000

    # 4. FORWARD rules
    iptables -D FORWARD -i br0 -o tun0 -j ACCEPT 2>/dev/null
    iptables -I FORWARD 1 -i br0 -o tun0 -j ACCEPT
    iptables -D FORWARD -i tun0 -o br0 -j ACCEPT 2>/dev/null
    iptables -I FORWARD 1 -i tun0 -o br0 -j ACCEPT

    # 5. Hijack LAN DNS into transparent proxy
    iptables -t nat -D PREROUTING -i br0 -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null
    iptables -t nat -D PREROUTING -i br0 -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null

    iptables -t nat -D PREROUTING -i br0 -p udp --dport 53 -j DNAT --to-destination 8.8.8.8:53 2>/dev/null
    iptables -t nat -I PREROUTING 1 -i br0 -p udp --dport 53 -j DNAT --to-destination 8.8.8.8:53
    iptables -t nat -D PREROUTING -i br0 -p tcp --dport 53 -j DNAT --to-destination 8.8.8.8:53 2>/dev/null
    iptables -t nat -I PREROUTING 1 -i br0 -p tcp --dport 53 -j DNAT --to-destination 8.8.8.8:53
}

cleanup_transparent_proxy() {
    # 1. Terminate sing-box
    killall sing-box 2>/dev/null
    sleep 1
    killall -9 sing-box 2>/dev/null

    # 2. Clean up policy routing
    ip rule del priority 7998 2>/dev/null
    ip rule del priority 8000 2>/dev/null
    ip rule del priority 9000 2>/dev/null
    ip rule del priority 9001 2>/dev/null
    ip rule del priority 9002 2>/dev/null
    ip rule del priority 9010 2>/dev/null
    ip route flush table 2022 2>/dev/null

    # 3. Ensure core routing rules exist
    ip rule show | grep -q "lookup local" || ip rule add lookup local pref 0 2>/dev/null
    ip rule show | grep -q "lookup main" || ip rule add lookup main pref 32766 2>/dev/null
    ip rule show | grep -q "lookup default" || ip rule add lookup default pref 32767 2>/dev/null

    # 4. Remove tun0 if present
    ip link delete tun0 2>/dev/null

    # 5. Clean up iptables rules
    iptables -D FORWARD -i br0 -o tun0 -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i tun0 -o br0 -j ACCEPT 2>/dev/null
    iptables -t nat -D PREROUTING -i br0 -p udp --dport 53 -j DNAT --to-destination 8.8.8.8:53 2>/dev/null
    iptables -t nat -D PREROUTING -i br0 -p tcp --dport 53 -j DNAT --to-destination 8.8.8.8:53 2>/dev/null
    iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null

    ip6tables -D FORWARD -i br0 -o rmnet_data0 -j DROP 2>/dev/null
    ip6tables -D FORWARD -p udp --dport 53 -j DROP 2>/dev/null
    ip6tables -D FORWARD -p tcp --dport 53 -j DROP 2>/dev/null
    ip6tables -D INPUT -i br0 -p udp --dport 53 -j DROP 2>/dev/null
    ip6tables -D INPUT -i br0 -p tcp --dport 53 -j DROP 2>/dev/null

    iptables -t nat -C PREROUTING -i br0 -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || \
    iptables -t nat -I PREROUTING 1 -i br0 -p udp --dport 53 -j REDIRECT --to-ports 53
    iptables -t nat -C PREROUTING -i br0 -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || \
    iptables -t nat -I PREROUTING 1 -i br0 -p tcp --dport 53 -j REDIRECT --to-ports 53

    [ -f /tmp/etc/radvd.conf ] && radvd -C /tmp/etc/radvd.conf 2>/dev/null
}

sync_dnsmasq_adblock() {
    cfg="/mnt/jffs2/proxy/config.json"
    ad_conf="/mnt/jffs2/proxy/adblock_dnsmasq.conf"
    mkdir -p /mnt/jffs2/proxy
    [ ! -f "$cfg" ] && return

    # Check if adblock is enabled (defaults to true if not explicitly false)
    if grep -q '"adblock_enabled":[ ]*false' "$cfg" 2>/dev/null; then
        > "$ad_conf"
    else
        # Extract blocked_ads_domains from config.json (block both IPv4 and IPv6)
        sed -n '/"blocked_ads_domains"/,/]/p' "$cfg" 2>/dev/null | grep '"' | grep -v 'blocked_ads_domains' | sed -e 's/^[ \t]*"//' -e 's/"[,\t ]*$//' | while read -r d; do
            if [ -n "$d" ]; then
                echo "address=/$d/0.0.0.0"
                echo "address=/$d/::"
            fi
        done > "$ad_conf"
    fi

    # Ensure /tmp/dnsmasq.conf includes this conf-file and reload dnsmasq
    if [ -f /tmp/dnsmasq.conf ]; then
        grep -q "conf-file=$ad_conf" /tmp/dnsmasq.conf || echo "conf-file=$ad_conf" >> /tmp/dnsmasq.conf
        sed -i '/127.0.0.1#6053/d' /tmp/dnsmasq.conf 2>/dev/null
        sed -i '/192.168.15.1#6053/d' /tmp/dnsmasq.conf 2>/dev/null
        sed -i '/223.5.5.5/d' /tmp/dnsmasq.conf 2>/dev/null
        sed -i '/strict-order/d' /tmp/dnsmasq.conf 2>/dev/null
        sed -i '/no-resolv/d' /tmp/dnsmasq.conf 2>/dev/null
        echo "server=127.0.0.1#6053" >> /tmp/dnsmasq.conf
        echo "no-resolv" >> /tmp/dnsmasq.conf
        echo "nameserver 127.0.0.1" > /tmp/etc/resolv.conf
        killall -9 dnsmasq dnsmasq.real dnsmasq_real 2>/dev/null
        sleep 1
        /usr/sbin/dnsmasq -i br0 -i lo --conntrack --bind-interfaces -K -N -C /tmp/dnsmasq.conf --pid-file=/var/run/dnsmasq.pid 2>/dev/null
    fi
}

# 4. Action: proxy_toggle
if [ "$ACTION" = "proxy_toggle" ]; then
    POST_DATA=$(read_post_data)
    enable=$(echo "$POST_DATA" | grep -o -E '(^|&)enable=[^&]*' | sed -e 's/^&//' -e 's/^enable=//')
    [ -z "$enable" ] && enable=$(echo "$POST_DATA" | sed -n 's/.*"enable":[ ]*\([0-9a-z]*\).*/\1/p')

    cfg_file="/mnt/jffs2/proxy/config.json"
    mkdir -p /mnt/jffs2/proxy

    if [ "$enable" = "1" ] || [ "$enable" = "true" ]; then
        mkdir -p /mnt/jffs2/ssl/certs
        grep -q " /etc/ssl/certs " /proc/mounts || mount --bind /mnt/jffs2/ssl/certs /etc/ssl/certs 2>/dev/null
        insmod /lib/modules/4.4.60/kernel/drivers/net/tun.ko 2>/dev/null
        mkdir -p /dev/net
        [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null
        
        killall -9 sing-box 2>/dev/null
        cleanup_transparent_proxy
        sleep 1

        # Prepare config: prefer flash saved config, fallback to default
        if [ -f /mnt/jffs2/proxy/sing-box.json ]; then
            cp -f /mnt/jffs2/proxy/sing-box.json /tmp/sing-box.json
        elif [ -x /mnt/jffs2/proxy/gen_config.sh ]; then
            /mnt/jffs2/proxy/gen_config.sh
        fi

        nohup /mnt/jffs2/proxy/sing-box run -c /tmp/sing-box.json >/tmp/sing-box.log 2>&1 &
        sleep 2
        
        running=false
        if pgrep -f "sing-box run" >/dev/null 2>&1; then
            running=true
            apply_transparent_proxy
            # Update enabled in config.json (ONLY at root level, first 5 lines!)
            if [ -f "$cfg_file" ]; then
                sed -i '1,5s/"enabled":[ ]*false/"enabled": true/' "$cfg_file" 2>/dev/null
            fi
            echo '{"success":true,"running":true,"message":"Proxy started successfully"}'
        else
            err=$(tail -n 5 /tmp/sing-box.log 2>/dev/null | tr '\n' ' ' | sed 's/"/\\"/g')
            echo "{\"success\":false,\"running\":false,\"error\":\"Failed to start: $err\"}"
        fi
    else
        # 1. First mark enabled: false at root level to prevent watchdog from resurrecting
        if [ -f "$cfg_file" ]; then
            sed -i '1,5s/"enabled":[ ]*true/"enabled": false/' "$cfg_file" 2>/dev/null
        fi
        # 2. Kill sing-box and remove all transparent proxy routing rules
        cleanup_transparent_proxy
        # 3. Even when transparent proxy is disabled, keep dnsmasq ad blocking active!
        sync_dnsmasq_adblock
        echo '{"success":true,"running":false,"message":"Transparent proxy disabled"}'
    fi
    exit 0
fi

# 5. Action: save_proxy_config (UI State)
if [ "$ACTION" = "save_proxy_config" ]; then
    mkdir -p /mnt/jffs2/proxy
    read_post_data > /mnt/jffs2/proxy/config.json
    sync_dnsmasq_adblock
    echo '{"success":true,"message":"UI configuration saved"}'
    exit 0
fi

# 6. Action: save_runtime_config (Sing-box Engine Config)
if [ "$ACTION" = "save_runtime_config" ]; then
    mkdir -p /mnt/jffs2/proxy
    read_post_data > /tmp/sing-box-new.json
    # Always enforce auto_route: false for host security and gateway stability
    sed -i 's/"auto_route":[ ]*true/"auto_route": false/g' /tmp/sing-box-new.json 2>/dev/null
    
    if /mnt/jffs2/proxy/sing-box check -c /tmp/sing-box-new.json >/tmp/sb_check.log 2>&1; then
        cp -f /tmp/sing-box-new.json /mnt/jffs2/proxy/sing-box.json
        cp -f /tmp/sing-box-new.json /tmp/sing-box.json
        
        # If proxy is currently enabled and running, restart it to apply new outbounds/rules
        cfg_file="/mnt/jffs2/proxy/config.json"
        if [ -f "$cfg_file" ] && head -n 5 "$cfg_file" | grep -q '"enabled":[ ]*true' 2>/dev/null; then
            if pgrep -f "sing-box run" >/dev/null 2>&1; then
                mkdir -p /mnt/jffs2/ssl/certs
                grep -q " /etc/ssl/certs " /proc/mounts || mount --bind /mnt/jffs2/ssl/certs /etc/ssl/certs 2>/dev/null
                killall -9 sing-box 2>/dev/null
                cleanup_transparent_proxy
                sleep 1
                nohup /mnt/jffs2/proxy/sing-box run -c /tmp/sing-box.json >/tmp/sing-box.log 2>&1 &
                sleep 2
                apply_transparent_proxy
            fi
        else
            killall -9 sing-box 2>/dev/null
            cleanup_transparent_proxy
        fi
        echo '{"success":true,"message":"Runtime config verified and applied"}'
    else
        err=$(cat /tmp/sb_check.log | tr '\n' ' ' | sed 's/"/\\"/g')
        echo "{\"success\":false,\"error\":\"$err\"}"
    fi
    exit 0
fi

# 7. Action: switch_node
if [ "$ACTION" = "switch_node" ]; then
    POST_DATA=$(read_post_data)
    node_tag=$(echo "$POST_DATA" | grep -o -E '(^|&)node=[^&]*' | sed -e 's/^&//' -e 's/^node=//')
    [ -z "$node_tag" ] && node_tag=$(echo "$POST_DATA" | sed -n 's/.*"node":[ ]*"\([^"]*\)".*/\1/p')
    # URL decode
    node_tag=$(printf '%b' "${node_tag//%/\\x}")

    if [ -n "$node_tag" ]; then
        # Hot-switch via Clash API
        curl -s -X PUT -d "{\"name\":\"$node_tag\"}" http://127.0.0.1:9090/proxies/GLOBAL >/dev/null 2>&1
        # Persist active_node in config.json
        cfg_file="/mnt/jffs2/proxy/config.json"
        if [ -f "$cfg_file" ]; then
            sed -i "s/\"active_node\":[ ]*\"[^\"]*\"/\"active_node\": \"$node_tag\"/" "$cfg_file" 2>/dev/null
        fi
        echo "{\"success\":true,\"active_node\":\"$node_tag\"}"
    else
        echo '{"success":false,"error":"Invalid node tag"}'
    fi
    exit 0
fi

# 8. Action: fetch_sub
if [ "$ACTION" = "fetch_sub" ]; then
    POST_DATA=$(read_post_data)
    sub_url=$(echo "$POST_DATA" | grep -o -E '(^|&)url=[^&]*' | sed -e 's/^&//' -e 's/^url=//')
    [ -z "$sub_url" ] && sub_url=$(echo "$POST_DATA" | sed -n 's/.*"url":[ ]*"\([^"]*\)".*/\1/p')
    # URL decode sub_url
    sub_url=$(printf '%b' "${sub_url//%/\\x}")

    if [ -n "$sub_url" ]; then
        tmp_sub="/tmp/sub_fetch_$$.tmp"
        rm -f "$tmp_sub"
        # 1. Direct fetch with modern UA
        curl -s -L -k --connect-timeout 10 -m 25 -A "ClashMeta;sing-box;v2rayN" "$sub_url" -o "$tmp_sub" 2>/dev/null
        # 2. Fallback via local proxy if failed/empty and sing-box is running
        if [ ! -s "$tmp_sub" ] && pgrep -f "sing-box run" >/dev/null 2>&1; then
            curl -s -L -k --connect-timeout 10 -m 25 --socks5-hostname 127.0.0.1:2080 -A "ClashMeta;sing-box;v2rayN" "$sub_url" -o "$tmp_sub" 2>/dev/null
        fi

        if [ -s "$tmp_sub" ]; then
            echo -n '{"success":true,"data_b64":"'
            openssl base64 -in "$tmp_sub" | tr -d '\r\n'
            echo '"}'
            rm -f "$tmp_sub"
        else
            rm -f "$tmp_sub"
            echo '{"success":false,"error":"拉取失败或订阅内容为空 (请检查网络连接或订阅链接)"}'
        fi
    else
        echo '{"success":false,"error":"Missing URL"}'
    fi
    exit 0
fi

# 9. Action: test_delay
if [ "$ACTION" = "test_delay" ]; then
    node_name=$(get_query_param "node")
    if [ -z "$node_name" ]; then
        echo '{"success":false,"error":"Missing node name","delay":-1}'
        exit 0
    fi

    # Ensure CA certs & environment
    mkdir -p /mnt/jffs2/ssl/certs
    grep -q " /etc/ssl/certs " /proc/mounts || mount --bind /mnt/jffs2/ssl/certs /etc/ssl/certs 2>/dev/null
    insmod /lib/modules/4.4.60/kernel/drivers/net/tun.ko 2>/dev/null
    mkdir -p /dev/net
    [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null

    # Ensure sing-box core is running for Clash API delay measurement
    # (Works even when TUN transparent proxy is disabled!)
    if ! pgrep -f "sing-box run" >/dev/null 2>&1; then
        if [ ! -f /tmp/.singbox_starting ]; then
            touch /tmp/.singbox_starting
            if [ -f /mnt/jffs2/proxy/sing-box.json ]; then
                cp -f /mnt/jffs2/proxy/sing-box.json /tmp/sing-box.json
            elif [ -x /mnt/jffs2/proxy/gen_config.sh ]; then
                /mnt/jffs2/proxy/gen_config.sh
            fi
            sed -i 's/"auto_route":[ ]*true/"auto_route": false/g' /tmp/sing-box.json 2>/dev/null
            nohup /mnt/jffs2/proxy/sing-box run -c /tmp/sing-box.json >/tmp/sing-box.log 2>&1 &
            sleep 2
            rm -f /tmp/.singbox_starting
        else
            sleep 1
        fi
    fi

    test_url=$(get_query_param "url")
    [ -z "$test_url" ] && test_url="http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204"

    # node_name was already percent-encoded by the client
    delay_resp=$(curl -s -m 8 "http://127.0.0.1:9090/proxies/$node_name/delay?timeout=6000&url=$test_url")
    if echo "$delay_resp" | grep -q "delay"; then
        echo "{\"success\":true,\"response\":$delay_resp}"
    else
        # Fallback to cloudflare generate_204 if gstatic failed
        delay_resp=$(curl -s -m 8 "http://127.0.0.1:9090/proxies/$node_name/delay?timeout=6000&url=http%3A%2F%2Fcp.cloudflare.com%2Fgenerate_204")
        if echo "$delay_resp" | grep -q "delay"; then
            echo "{\"success\":true,\"response\":$delay_resp}"
        else
            echo '{"success":false,"delay":-1}'
        fi
    fi
    exit 0
fi

# 10. Action: get_outbound_ip
if [ "$ACTION" = "get_outbound_ip" ]; then
    out_ip=$(curl -s -m 5 --socks5 127.0.0.1:2080 http://api.ipify.org 2>/dev/null | tr -d '\r\n')
    wan_ip=$(curl -s -m 5 http://api.ipify.org 2>/dev/null | tr -d '\r\n')
    [ -z "$out_ip" ] && out_ip="获取超时"
    [ -z "$wan_ip" ] && wan_ip="N/A"
    echo "{\"success\":true,\"proxy_ip\":\"$out_ip\",\"wan_ip\":\"$wan_ip\"}"
    exit 0
fi

# 11. Action: smartdns_restart
if [ "$ACTION" = "smartdns_restart" ]; then
    killall smartdns 2>/dev/null
    if [ ! -f /tmp/anti-ad-for-smartdns.conf ] && [ -f /mnt/jffs2/proxy/anti-ad.conf.gz ]; then
        gzip -dc /mnt/jffs2/proxy/anti-ad.conf.gz > /tmp/anti-ad-for-smartdns.conf 2>/dev/null
    fi
    if [ -f /mnt/jffs2/proxy/smartdns ] && [ -f /mnt/jffs2/proxy/smartdns.conf ]; then
        /mnt/jffs2/proxy/smartdns -c /mnt/jffs2/proxy/smartdns.conf >/dev/null 2>&1
        sleep 1
    fi
    sync_dnsmasq_adblock
    smartdns_running="false"
    pgrep -f "smartdns.*smartdns.conf" >/dev/null 2>&1 && smartdns_running="true"
    rule_count=0
    [ -f /tmp/anti-ad-for-smartdns.conf ] && rule_count=$(wc -l < /tmp/anti-ad-for-smartdns.conf 2>/dev/null | tr -d ' ')
    cat <<EOF
{
  "success": true,
  "smartdns_active": $smartdns_running,
  "rules_count": $rule_count,
  "message": "SmartDNS restarted successfully"
}
EOF
    exit 0
fi

# 12. Action: adblock_check
if [ "$ACTION" = "adblock_check" ]; then
    smartdns_running="false"
    pgrep -f "smartdns.*smartdns.conf" >/dev/null 2>&1 && smartdns_running="true"

    # Self-healing: if smartdns died, automatically start it!
    if [ "$smartdns_running" = "false" ]; then
        if [ -f /mnt/jffs2/proxy/smartdns ] && [ -f /mnt/jffs2/proxy/smartdns.conf ]; then
            if [ ! -f /tmp/anti-ad-for-smartdns.conf ] && [ -f /mnt/jffs2/proxy/anti-ad.conf.gz ]; then
                gzip -dc /mnt/jffs2/proxy/anti-ad.conf.gz > /tmp/anti-ad-for-smartdns.conf 2>/dev/null
            fi
            /mnt/jffs2/proxy/smartdns -c /mnt/jffs2/proxy/smartdns.conf >/dev/null 2>&1
            sleep 1
            pgrep -f "smartdns.*smartdns.conf" >/dev/null 2>&1 && smartdns_running="true"
        fi
        sync_dnsmasq_adblock
    fi

    rule_count=0
    [ -f /tmp/anti-ad-for-smartdns.conf ] && rule_count=$(wc -l < /tmp/anti-ad-for-smartdns.conf 2>/dev/null | tr -d ' ')

    check_dom() {
        d="$1"
        res=$(nslookup "$d" 2>/dev/null | grep 'Address 1:' | tail -n 1 | cut -d' ' -f3 | tr -d '\r\n')
        [ -z "$res" ] && res="NXDOMAIN"
        echo "$res"
    }

    pangle_ip=$(check_dom "pangle.cn")
    gdt_ip=$(check_dom "gdt.qq.com")
    mobads_ip=$(check_dom "mobads.baidu.com")
    kuaishou_ip=$(check_dom "e.kuaishou.com")
    kugou_ad_ip=$(check_dom "ads.service.kugou.com")
    kglink_ad_ip=$(check_dom "ads.service.kglink.com")
    tmead_ip=$(check_dom "tmead.y.qq.com")
    kugou_music_ip=$(check_dom "trackercdn.kugou.com")
    biliad_ip=$(check_dom "cm.bilibili.com")
    baidu_ip=$(check_dom "www.baidu.com")
    bilibili_ip=$(check_dom "www.bilibili.com")

    is_b() {
        ip="$1"
        if [ "$ip" = "0.0.0.0" ] || [ "$ip" = "NXDOMAIN" ] || [ "$ip" = "::" ]; then
            echo "true"
        else
            echo "false"
        fi
    }

    cat <<EOF
{
  "success": true,
  "router_model": "Linksys FGW3000",
  "smartdns_active": $smartdns_running,
  "rules_count": $rule_count,
  "tests": [
    {"name": "字节跳动穿山甲广告", "domain": "pangle.cn", "isAd": true, "ip": "$pangle_ip", "blocked": $(is_b "$pangle_ip")},
    {"name": "腾讯优量汇广告联盟", "domain": "gdt.qq.com", "isAd": true, "ip": "$gdt_ip", "blocked": $(is_b "$gdt_ip")},
    {"name": "百度百青藤广告联盟", "domain": "mobads.baidu.com", "isAd": true, "ip": "$mobads_ip", "blocked": $(is_b "$mobads_ip")},
    {"name": "快手广告联盟", "domain": "e.kuaishou.com", "isAd": true, "ip": "$kuaishou_ip", "blocked": $(is_b "$kuaishou_ip")},
    {"name": "酷狗音乐核心广告服务", "domain": "ads.service.kugou.com", "isAd": true, "ip": "$kugou_ad_ip", "blocked": $(is_b "$kugou_ad_ip")},
    {"name": "酷狗kglink广告与回传", "domain": "ads.service.kglink.com", "isAd": true, "ip": "$kglink_ad_ip", "blocked": $(is_b "$kglink_ad_ip")},
    {"name": "TME腾讯音乐广告联盟", "domain": "tmead.y.qq.com", "isAd": true, "ip": "$tmead_ip", "blocked": $(is_b "$tmead_ip")},
    {"name": "B站商业打点接口", "domain": "cm.bilibili.com", "isAd": true, "ip": "$biliad_ip", "blocked": $(is_b "$biliad_ip")},
    {"name": "酷狗音乐正常歌曲播放", "domain": "trackercdn.kugou.com", "isAd": false, "ip": "$kugou_music_ip", "blocked": $(is_b "$kugou_music_ip")},
    {"name": "正常国内网站 (百度)", "domain": "www.baidu.com", "isAd": false, "ip": "$baidu_ip", "blocked": $(is_b "$baidu_ip")},
    {"name": "正常国内网站 (B站主站)", "domain": "www.bilibili.com", "isAd": false, "ip": "$bilibili_ip", "blocked": $(is_b "$bilibili_ip")}
  ]
}
EOF
    exit 0
fi

# 13. Action: get_sms
if [ "$ACTION" = "get_sms" ]; then
    refresh=$(get_query_param "refresh")
    if [ "$refresh" = "1" ] || [ ! -f "/tmp/inbox.json" ]; then
        /mnt/jffs2/read_sms.sh >/dev/null 2>&1
    fi
    if [ -f "/tmp/inbox.json" ]; then
        cat /tmp/inbox.json
    else
        echo '{"ok":true,"count":0,"messages":[]}'
    fi
    exit 0
fi

# 14. Action: send_sms
if [ "$ACTION" = "send_sms" ]; then
    to=$(get_query_param "to")
    msg=$(get_query_param "msg")
    
    if [ -z "$to" ]; then
        body=$(read_post_data)
        to=$(echo "$body" | grep -o '"to":[ ]*"[^"]*"' | awk -F: '{print $2}' | tr -d ' "')
        msg=$(echo "$body" | grep -o '"msg":[ ]*"[^"]*"' | awk -F: '{print $2}' | tr -d ' "')
    fi
    
    to=$(printf '%b' "${to//%/\\x}" 2>/dev/null || echo "$to")
    msg=$(printf '%b' "${msg//%/\\x}" 2>/dev/null || echo "$msg")
    
    if [ -z "$to" ] || [ -z "$msg" ]; then
        echo '{"success":false,"error":"缺少收件人号码或内容"}'
        exit 0
    fi
    
    /mnt/jffs2/sms_send.sh "$to" "$msg"
    exit 0
fi

# 15. Action: delete_sms
if [ "$ACTION" = "delete_sms" ]; then
    idx=$(get_query_param "index")
    st=$(get_query_param "storage")
    [ -z "$st" ] && st="SM"
    if [ -n "$idx" ]; then
        /mnt/jffs2/delete_sms.sh "$idx" "$st"
    else
        echo '{"success":false,"error":"缺少短信索引"}'
    fi
    exit 0
fi

if [ "$ACTION" = "batch_delete_sms" ]; then
    items=$(get_query_param "items")
    if [ -z "$items" ]; then
        body=$(read_post_data)
        items=$(echo "$body" | grep -o '"items":[ ]*"[^"]*"' | awk -F: '{print $2}' | tr -d ' "')
        [ -z "$items" ] && items=$(echo "$body" | sed -e 's/.*items=//' -e 's/&.*//')
    fi
    if [ -n "$items" ]; then
        /mnt/jffs2/delete_sms.sh "batch" "$items"
    else
        echo '{"success":false,"error":"缺少删除列表"}'
    fi
    exit 0
fi

if [ "$ACTION" = "delete_all_sms" ]; then
    /mnt/jffs2/delete_sms.sh "all"
    exit 0
fi

# 16. Action: get_forward_config
if [ "$ACTION" = "get_forward_config" ]; then
    cfg="/mnt/jffs2/conf/user/sms_forward.json"
    if [ -f "$cfg" ]; then
        cat "$cfg"
    else
        cat << 'EOF'
{
  "enabled": false,
  "channel": "pushplus",
  "pushplus_token": "",
  "bark_url": "",
  "bark_sound": "minuet",
  "tg_bot_token": "",
  "tg_chat_id": "",
  "webhook_url": ""
}
EOF
    fi
    exit 0
fi

# 17. Action: save_forward_config
if [ "$ACTION" = "save_forward_config" ]; then
    cfg="/mnt/jffs2/conf/user/sms_forward.json"
    body=$(read_post_data)
    mkdir -p /mnt/jffs2/conf/user
    if [ -n "$body" ]; then
        echo "$body" > "$cfg"
        killall -9 sms_forwarder.sh 2>/dev/null
        nohup /mnt/jffs2/sms_forwarder.sh >/dev/null 2>&1 &
        echo '{"success":true,"message":"配置已保存，推送守护已即刻生效"}'
    else
        echo '{"success":false,"error":"配置体为空"}'
    fi
    exit 0
fi

# 18. Action: test_forward
if [ "$ACTION" = "test_forward" ]; then
    cfg="/mnt/jffs2/conf/user/sms_forward.json"
    req_ch=$(get_query_param "channel")
    
    pushplus_token=$(grep -o '"pushplus_token":[ ]*"[^"]*"' "$cfg" 2>/dev/null | awk -F: '{print $2}' | tr -d ' "')
    bark_url=$(grep -o '"bark_url":[ ]*"[^"]*"' "$cfg" 2>/dev/null | awk -F: '{print $2}' | tr -d ' "')
    tg_token=$(grep -o '"tg_bot_token":[ ]*"[^"]*"' "$cfg" 2>/dev/null | awk -F: '{print $2}' | tr -d ' "')
    tg_chat=$(grep -o '"tg_chat_id":[ ]*"[^"]*"' "$cfg" 2>/dev/null | awk -F: '{print $2}' | tr -d ' "')
    webhook=$(grep -o '"webhook_url":[ ]*"[^"]*"' "$cfg" 2>/dev/null | awk -F: '{print $2}' | tr -d ' "')
    
    smtp_host=$(grep -o '"smtp_host":[ ]*"[^"]*"' "$cfg" 2>/dev/null | awk -F: '{print $2}' | tr -d ' "')
    [ -z "$smtp_host" ] && smtp_host="smtp.qq.com"
    smtp_port=$(grep -o '"smtp_port":[ ]*[^,}]*' "$cfg" 2>/dev/null | awk -F: '{print $2}' | tr -d ' "')
    [ -z "$smtp_port" ] && smtp_port="465"
    smtp_user=$(grep -o '"smtp_user":[ ]*"[^"]*"' "$cfg" 2>/dev/null | awk -F: '{print $2}' | tr -d ' "')
    smtp_pass=$(grep -o '"smtp_pass":[ ]*"[^"]*"' "$cfg" 2>/dev/null | awk -F: '{print $2}' | tr -d ' "')
    mail_to=$(grep -o '"mail_to":[ ]*"[^"]*"' "$cfg" 2>/dev/null | awk -F: '{print $2}' | tr -d ' "')
    
    res=""
    
    # 邮件测试
    if [ "$req_ch" = "email" ] || [ -z "$req_ch" -a -n "$smtp_user" ]; then
        if [ -n "$smtp_user" ] && [ -n "$smtp_pass" ] && [ -n "$mail_to" ]; then
            eml="/tmp/test_fwd.eml"
            b64_sub=$(printf "【8848】测试验证码 · 来自 10086" | openssl base64 -A 2>/dev/null)
            cat > "$eml" << EOF
From: "FGW3000 短信中心" <$smtp_user>
To: <$mail_to>
Subject: =?UTF-8?B?$b64_sub?=
Content-Type: text/html; charset=UTF-8

<div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:540px;margin:20px auto;padding:24px;background:#ffffff;border:1px solid #e5e5ea;border-radius:16px;color:#1d1d1f;">
  <div style="display:flex;align-items:center;gap:10px;margin-bottom:16px;">
    <div style="width:36px;height:36px;border-radius:8px;background:#0071E3;display:flex;align-items:center;justify-content:center;color:#fff;font-weight:bold;font-size:18px;">L</div>
    <div>
      <h3 style="margin:0;color:#1d1d1f;font-size:16px;">【8848】测试验证码 · 来自 10086</h3>
      <p style="margin:2px 0 0;color:#86868b;font-size:12px;">Linksys FGW3000 5G CPE 邮件转发测试</p>
    </div>
  </div>
  <div style="margin:16px 0;padding:18px;background:#f0f7ff;border:1px solid rgba(0,113,227,0.15);border-radius:12px;text-align:center;">
    <span style="font-size:12px;color:#0071E3;font-weight:600;letter-spacing:1px;">提取验证码</span>
    <div style="font-size:36px;font-weight:700;color:#0071E3;letter-spacing:6px;margin-top:6px;font-family:ui-monospace,Menlo,monospace;">8848</div>
  </div>
  <table style="width:100%;font-size:13px;border-collapse:collapse;margin-top:18px;">
    <tr><td style="padding:7px 0;color:#86868b;width:70px;">发件号码</td><td style="padding:7px 0;font-weight:600;font-family:ui-monospace,Menlo,monospace;">10086</td></tr>
    <tr><td style="padding:7px 0;color:#86868b;">接收时间</td><td style="padding:7px 0;">$(date '+%Y-%m-%d %H:%M:%S')</td></tr>
    <tr><td style="padding:7px 0;color:#86868b;vertical-align:top;">测试正文</td><td style="padding:7px 0;line-height:1.5;">这是一条来自 Linksys FGW3000 的测试邮件，说明邮件转发通道完全畅通！</td></tr>
  </table>
  <hr style="border:none;border-top:1px solid #f0f0f2;margin:20px 0 10px;">
  <p style="margin:0;font-size:11px;color:#a1a1a6;text-align:center;">由 Linksys FGW3000 (China Mobile 4G/5G) 自动发送</p>
</div>
EOF
            curl -k -s -m 12 --ssl-reqd \
                --url "smtps://$smtp_host:$smtp_port" \
                --login-options 'AUTH=LOGIN' \
                --user "$smtp_user:$smtp_pass" \
                --mail-from "$smtp_user" \
                --mail-rcpt "$mail_to" \
                --upload-file "$eml" >/dev/null 2>&1
            rm -f "$eml"
            res="邮件测试已发送至 $mail_to"
        fi
    fi

    # PushPlus 测试
    if [ "$req_ch" = "pushplus" ] || [ -z "$req_ch" -a -n "$pushplus_token" ]; then
        if [ -n "$pushplus_token" ]; then
            res=$(curl -s -m 8 -X POST 'http://www.pushplus.plus/send' \
                -H 'Content-Type: application/json' \
                -d "{\"token\":\"$pushplus_token\",\"title\":\"【8848】测试验证码 · 来自 10086\",\"content\":\"这是一条来自 Linksys FGW3000 路由器的测试通知！<br><b>测试验证码</b>：<span style=\\\"color:#0071E3;font-size:24px;font-weight:bold;\\\">8848</span><br>发件人：10086<br>时间：$(date '+%Y-%m-%d %H:%M:%S')\",\"template\":\"html\"}" 2>&1)
        fi
    fi

    if [ "$req_ch" = "bark" ] && [ -n "$bark_url" ]; then
        b_url=$(echo "$bark_url" | sed 's|/*$||')
        res=$(curl -k -s -m 8 "$b_url/%E3%80%908848%E3%80%91%E6%B5%8B%E8%AF%95%E9%AA%8C%E8%AF%81%E7%A0%81/%E7%9F%AD%E4%BF%A1%E8%BD%AC%E5%8F%91%E6%9C%8D%E5%8A%A1%E6%B5%8B%E8%AF%95%E6%88%90%E5%8A%9F%EF%BC%81?copy=8848&group=CPE%E6%B5%8B%E8%AF%95" 2>&1)
    fi
    if [ "$req_ch" = "telegram" ] && [ -n "$tg_token" ] && [ -n "$tg_chat" ]; then
        res=$(curl -k -s -m 8 "https://api.telegram.org/bot$tg_token/sendMessage" -d "chat_id=$tg_chat" --data-urlencode "text=🔔 *【8848】测试验证码 · 来自 10086*%0A%0A这是一条来自 Linksys FGW3000 的测试通知" 2>&1)
    fi
    if [ "$req_ch" = "webhook" ] && [ -n "$webhook" ]; then
        res=$(curl -k -s -m 8 -X POST -H "Content-Type: application/json" -d '{"title":"【8848】测试验证码","content":"测试通知","code":"8848"}' "$webhook" 2>&1)
    fi
    
    res_esc=$(printf '%s' "$res" | tr -d '\r\n' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    echo "{\"success\":true,\"message\":\"测试推送已发出，请查收！\",\"response\":\"$res_esc\"}"
    exit 0
fi

# 19. Action: orch_net
if [ "$ACTION" = "orch_net" ]; then
    nohup /mnt/jffs2/net_orchestrator.sh >/dev/null 2>&1 &
    echo '{"success":true,"message":"网络承载与 IP 刷新中"}'
    exit 0
fi

# 20. Action: reboot_modem
if [ "$ACTION" = "reboot_modem" ]; then
    (
        killall -SIGALRM lte_mgr 2>/dev/null
        sleep 2
        /bin/reboot_sdx55.sh 2>/dev/null || reboot_sdx55.sh 2>/dev/null
    ) >/dev/null 2>&1 &
    echo '{"success":true,"message":"已向 SDX55 发出重启指令"}'
    exit 0
fi

echo '{"error":"Invalid action"}'
exit 0

