#!/bin/sh
# ==============================================================================
# Linksys FGW3000 Proxy Watchdog & Anti-Leak Daemon
# ==============================================================================

LOG_FILE="/tmp/proxy_watchdog.log"
CONFIG_FILE="/mnt/jffs2/proxy/config.json"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WATCHDOG] $1" >> "$LOG_FILE" 2>/dev/null
}

apply_transparent_rules() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    killall radvd 2>/dev/null

    ifconfig tun0 mtu 1400 2>/dev/null
    iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
    iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

    ip6tables -C FORWARD -i br0 -o rmnet_data0 -j DROP 2>/dev/null || ip6tables -I FORWARD 1 -i br0 -o rmnet_data0 -j DROP
    ip6tables -C FORWARD -p udp --dport 53 -j DROP 2>/dev/null || ip6tables -I FORWARD 1 -p udp --dport 53 -j DROP
    ip6tables -C FORWARD -p tcp --dport 53 -j DROP 2>/dev/null || ip6tables -I FORWARD 1 -p tcp --dport 53 -j DROP
    ip6tables -C INPUT -i br0 -p udp --dport 53 -j DROP 2>/dev/null || ip6tables -I INPUT 1 -i br0 -p udp --dport 53 -j DROP
    ip6tables -C INPUT -i br0 -p tcp --dport 53 -j DROP 2>/dev/null || ip6tables -I INPUT 1 -i br0 -p tcp --dport 53 -j DROP

    ip route replace default dev tun0 table 2022 2>/dev/null
    ip rule del priority 7998 2>/dev/null
    ip rule del priority 8000 2>/dev/null
    ip rule add to 192.168.15.0/24 lookup main priority 7998
    ip rule add iif br0 lookup 2022 priority 8000

    iptables -C FORWARD -i br0 -o tun0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i br0 -o tun0 -j ACCEPT
    iptables -C FORWARD -i tun0 -o br0 -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i tun0 -o br0 -j ACCEPT

    iptables -t nat -D PREROUTING -i br0 -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null
    iptables -t nat -D PREROUTING -i br0 -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null

    iptables -t nat -C PREROUTING -i br0 -p udp --dport 53 -j DNAT --to-destination 8.8.8.8:53 2>/dev/null || iptables -t nat -I PREROUTING 1 -i br0 -p udp --dport 53 -j DNAT --to-destination 8.8.8.8:53
    iptables -t nat -C PREROUTING -i br0 -p tcp --dport 53 -j DNAT --to-destination 8.8.8.8:53 2>/dev/null || iptables -t nat -I PREROUTING 1 -i br0 -p tcp --dport 53 -j DNAT --to-destination 8.8.8.8:53

    for hip in 203.107.1.1 203.107.1.33 203.107.1.34 119.29.29.98 119.29.29.99 182.254.116.116 180.76.76.200; do
        iptables -C FORWARD -d $hip -j REJECT 2>/dev/null || iptables -I FORWARD 1 -d $hip -j REJECT
    done
}

cleanup_transparent_rules() {
    killall sing-box 2>/dev/null
    sleep 1
    killall -9 sing-box 2>/dev/null

    ip rule del priority 7998 2>/dev/null
    ip rule del priority 8000 2>/dev/null
    ip rule del priority 9000 2>/dev/null
    ip rule del priority 9001 2>/dev/null
    ip rule del priority 9002 2>/dev/null
    ip rule del priority 9010 2>/dev/null
    ip route flush table 2022 2>/dev/null

    ip rule show | grep -q "lookup local" || ip rule add lookup local pref 0 2>/dev/null
    ip rule show | grep -q "lookup main" || ip rule add lookup main pref 32766 2>/dev/null
    ip rule show | grep -q "lookup default" || ip rule add lookup default pref 32767 2>/dev/null

    ip link delete tun0 2>/dev/null

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

while true; do
    # 0. 核心路由基准保障（防止误删或策略路由混乱导致断网）
    ip rule show | grep -q "lookup local" || ip rule add lookup local pref 0 2>/dev/null
    ip rule show | grep -q "lookup main" || ip rule add lookup main pref 32766 2>/dev/null
    ip rule show | grep -q "lookup default" || ip rule add lookup default pref 32767 2>/dev/null

    # 0.1 确保 Web 允许纯 HTTP 并且禁用 HSTS 强跳
    if [ ! -f /tmp/.lighttpd_patched ]; then
        cp /etc/lighttpd/lighttpd.conf.sh /tmp/lighttpd.conf.sh 2>/dev/null
        sed -i '2a export BR2_GEMTEK_UI_SUPPORT_HTTP=y' /tmp/lighttpd.conf.sh 2>/dev/null
        cp /etc/lighttpd/lighttpd.conf /tmp/lighttpd.conf 2>/dev/null
        sed -i 's/max-age=63072000/max-age=0/g' /tmp/lighttpd.conf 2>/dev/null
        grep -q " /etc/lighttpd/lighttpd.conf.sh " /proc/mounts || mount --bind /tmp/lighttpd.conf.sh /etc/lighttpd/lighttpd.conf.sh 2>/dev/null
        grep -q " /etc/lighttpd/lighttpd.conf " /proc/mounts || mount --bind /tmp/lighttpd.conf /etc/lighttpd/lighttpd.conf 2>/dev/null
        killall lighttpd 2>/dev/null
        /usr/sbin/lighttpd -f /etc/lighttpd/lighttpd.conf >/dev/null 2>&1
        touch /tmp/.lighttpd_patched
    fi

    # 0.2 确保 dnsmasq wrapper 挂载生效（使用 /proc/mounts 避免重复堆叠挂载）
    if [ -f /mnt/jffs2/proxy/dnsmasq_wrapper.sh ] && ! grep -q " /usr/sbin/dnsmasq " /proc/mounts; then
        [ -f /tmp/dnsmasq.real ] || cp /usr/sbin/dnsmasq /tmp/dnsmasq.real
        chmod +x /tmp/dnsmasq.real
        mount --bind /mnt/jffs2/proxy/dnsmasq_wrapper.sh /usr/sbin/dnsmasq 2>/dev/null
    fi

    # 0.3 确保 Crontab 防篡改与 crond 守护常驻
    CRON_DIR="/mnt/jffs2/conf/app"
    for cron_f in "$CRON_DIR/crontab.tab" "$CRON_DIR/root"; do
        if [ ! -f "$cron_f" ] || ! grep -q '/mnt/jffs2/startup.sh' "$cron_f" 2>/dev/null; then
            chattr -i "$cron_f" 2>/dev/null
            echo "30 2 * * * /bin/mc_trigger fota_alarm 3" > "$cron_f" 2>/dev/null
            echo "* * * * * /mnt/jffs2/startup.sh >/dev/null 2>&1" >> "$cron_f" 2>/dev/null
            chmod 600 "$cron_f" 2>/dev/null
            chattr +i "$cron_f" 2>/dev/null
        fi
    done
    if ! pgrep -f "crond.*conf/app" >/dev/null 2>&1; then
        crond -c "$CRON_DIR" 2>/dev/null
    fi

    # 1. 保活 SmartDNS
    if ! pgrep -f "smartdns.*smartdns.conf" >/dev/null 2>&1; then
        if [ -f /mnt/jffs2/proxy/smartdns ] && [ -f /mnt/jffs2/proxy/smartdns.conf ]; then
            log "SmartDNS died. Restarting..."
            if [ ! -f /tmp/anti-ad-for-smartdns.conf ] && [ -f /mnt/jffs2/proxy/anti-ad.conf.gz ]; then
                gzip -dc /mnt/jffs2/proxy/anti-ad.conf.gz > /tmp/anti-ad-for-smartdns.conf 2>/dev/null
            fi
            /mnt/jffs2/proxy/smartdns -c /mnt/jffs2/proxy/smartdns.conf >/dev/null 2>&1
        fi
    fi

    # 2. 保证 Dnsmasq 指向 SmartDNS (6053) 与备用公共 DNS (223.5.5.5)
    #    仅在启用 SmartDNS 时执行，否则保持原厂 DNS，避免指向不存在的 6053 断网。
    if [ -f /mnt/jffs2/proxy/smartdns ]; then
        DNSMASQ_DIRTY=0
        ad_conf="/mnt/jffs2/proxy/adblock_dnsmasq.conf"
        if [ -f /tmp/dnsmasq.conf ]; then
            if ! grep -q "127.0.0.1#6053" /tmp/dnsmasq.conf || ([ -f "$ad_conf" ] && ! grep -q "conf-file=$ad_conf" /tmp/dnsmasq.conf); then
                log "Dnsmasq upstream lost. Re-pointing to SmartDNS 6053..."
                [ -f "$ad_conf" ] && (grep -q "conf-file=$ad_conf" /tmp/dnsmasq.conf || echo "conf-file=$ad_conf" >> /tmp/dnsmasq.conf)
                sed -i '/127.0.0.1#6053/d' /tmp/dnsmasq.conf 2>/dev/null
                sed -i '/192.168.15.1#6053/d' /tmp/dnsmasq.conf 2>/dev/null
                sed -i '/223.5.5.5/d' /tmp/dnsmasq.conf 2>/dev/null
                sed -i '/strict-order/d' /tmp/dnsmasq.conf 2>/dev/null
                sed -i '/no-resolv/d' /tmp/dnsmasq.conf 2>/dev/null
                echo "strict-order" >> /tmp/dnsmasq.conf
                echo "server=127.0.0.1#6053" >> /tmp/dnsmasq.conf
                echo "server=223.5.5.5" >> /tmp/dnsmasq.conf
                echo "no-resolv" >> /tmp/dnsmasq.conf
                DNSMASQ_DIRTY=1
            fi
        fi
        if ! grep -q "127.0.0.1" /tmp/etc/resolv.conf 2>/dev/null; then
            echo "nameserver 127.0.0.1" > /tmp/etc/resolv.conf
        fi
        if [ "$DNSMASQ_DIRTY" -eq 1 ] || ! pgrep -f "dnsmasq.*dnsmasq.conf" >/dev/null 2>&1; then
            killall -9 dnsmasq dnsmasq.real dnsmasq_real 2>/dev/null
            sleep 1
            /usr/sbin/dnsmasq -i br0 -i lo --conntrack --bind-interfaces -K -N -C /tmp/dnsmasq.conf --pid-file=/var/run/dnsmasq.pid 2>/dev/null
        fi
    fi

    # 3. 根除 IPv6 运营商 DNS 广播投毒并封禁外发 IPv6 DNS
    if [ -f /tmp/etc/radvd.conf ] && grep -q "RDNSS" /tmp/etc/radvd.conf; then
        log "Removing IPv6 ISP DNS from radvd..."
        sed -i '/RDNSS/,/};/d' /tmp/etc/radvd.conf 2>/dev/null
        killall -HUP radvd 2>/dev/null
    fi
    ip6tables -C FORWARD -p udp --dport 53 -j REJECT 2>/dev/null || ip6tables -I FORWARD 1 -p udp --dport 53 -j REJECT
    ip6tables -C FORWARD -p tcp --dport 53 -j REJECT 2>/dev/null || ip6tables -I FORWARD 1 -p tcp --dport 53 -j REJECT
#     iptables -C FORWARD -p tcp --dport 853 -j REJECT 2>/dev/null || iptables -I FORWARD 1 -p tcp --dport 853 -j REJECT
#     ip6tables -C FORWARD -p tcp --dport 853 -j REJECT 2>/dev/null || ip6tables -I FORWARD 1 -p tcp --dport 853 -j REJECT

    # 4. 全天候阻断 HttpDNS 探针
    for hip in 203.107.1.1 203.107.1.33 203.107.1.34 119.29.29.98 119.29.29.99 182.254.116.116 180.76.76.200; do
        iptables -C FORWARD -d $hip -j REJECT 2>/dev/null || iptables -I FORWARD 1 -d $hip -j REJECT
    done
    iptables -C FORWARD -p tcp -m multiport --dports 80,443,8080 -d 119.29.29.29 -j REJECT 2>/dev/null || iptables -I FORWARD 1 -p tcp -m multiport --dports 80,443,8080 -d 119.29.29.29 -j REJECT

    # 5. 保活 Sing-box 及透明策略状态对齐
    is_enabled=false
    if [ -f "$CONFIG_FILE" ] && head -n 5 "$CONFIG_FILE" | grep -q '"enabled":[ ]*true' 2>/dev/null; then
        is_enabled=true
    fi

    if [ "$is_enabled" = "true" ]; then
        if ! pgrep -f "sing-box run" >/dev/null 2>&1; then
            log "sing-box died unexpectedly. Restarting..."
            if [ -f /mnt/jffs2/proxy/sing-box.json ]; then
                insmod /lib/modules/4.4.60/kernel/drivers/net/tun.ko 2>/dev/null
                mkdir -p /dev/net
                [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null
                cp -f /mnt/jffs2/proxy/sing-box.json /tmp/sing-box.json
                nohup /mnt/jffs2/proxy/sing-box run -c /tmp/sing-box.json >/tmp/sing-box.log 2>&1 &
                sleep 2
            fi
        fi

        if ! iptables -t nat -C PREROUTING -i br0 -p udp --dport 53 -j DNAT --to-destination 8.8.8.8:53 2>/dev/null; then
            log "Firewall flush detected! Restoring transparent proxy rules..."
            apply_transparent_rules
        elif pgrep radvd >/dev/null 2>&1; then
            killall radvd 2>/dev/null
        fi
    else
        # 代理未启用：确保局域网 DNS 重定向至本地 SmartDNS，且清理残留 sing-box/规则
        iptables -t nat -C PREROUTING -i br0 -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || \
        iptables -t nat -I PREROUTING 1 -i br0 -p udp --dport 53 -j REDIRECT --to-ports 53
        iptables -t nat -C PREROUTING -i br0 -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || \
        iptables -t nat -I PREROUTING 1 -i br0 -p tcp --dport 53 -j REDIRECT --to-ports 53

        if iptables -t nat -C PREROUTING -i br0 -p udp --dport 53 -j DNAT --to-destination 8.8.8.8:53 2>/dev/null || ip rule show | grep -q "lookup 2022"; then
            log "Proxy disabled in config. Cleaning residual routing rules..."
            cleanup_transparent_rules
        elif pgrep -f "sing-box run" >/dev/null 2>&1; then
            # 代理关闭但 sing-box 运行时（可能来自前端测速）：宽限 120 秒后释放内存
            cnt=$(cat /tmp/.singbox_idle_count 2>/dev/null || echo 0)
            cnt=$((cnt + 1))
            echo "$cnt" > /tmp/.singbox_idle_count
            if [ "$cnt" -ge 8 ]; then
                log "Idle sing-box stopped to save RAM (proxy disabled)."
                killall sing-box 2>/dev/null
                rm -f /tmp/.singbox_idle_count
            fi
        else
            rm -f /tmp/.singbox_idle_count 2>/dev/null
        fi
    fi

    # 6. 内存日志滚动防爆限额（防止长期运行导致 /tmp 内存耗尽）
    for lf in "$LOG_FILE" /tmp/sing-box.log /tmp/dnsmasq.log /tmp/smartdns.log; do
        if [ -f "$lf" ]; then
            sz=$(wc -c < "$lf" 2>/dev/null || echo 0)
            if [ "$sz" -gt 300000 ]; then
                tail -n 1000 "$lf" > "$lf.tmp" 2>/dev/null && mv -f "$lf.tmp" "$lf"
            fi
        fi
    done

    sleep 15
done
