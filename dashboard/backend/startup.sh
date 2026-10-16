#!/bin/sh
# ==============================================================================
# Linksys FGW3000 System Auto-Start & Watchdog Orchestrator
# Flash-persistent on /mnt/jffs2/startup.sh
# ==============================================================================

# 0. 核心路由基准规则保障（防止误删或异常导致的断网）
ip rule show | grep -q "lookup local" || ip rule add lookup local pref 0 2>/dev/null
ip rule show | grep -q "lookup main" || ip rule add lookup main pref 32766 2>/dev/null
ip rule show | grep -q "lookup default" || ip rule add lookup default pref 32767 2>/dev/null
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
ip6tables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu


# 1. 确保 Crontab 自动持久化注入与不可篡改保障（开机自动执行保障）
CRON_DIR="/mnt/jffs2/conf/app"
mkdir -p "$CRON_DIR"
for cron_f in "$CRON_DIR/crontab.tab" "$CRON_DIR/root"; do
    if [ ! -f "$cron_f" ] || ! grep -q '/mnt/jffs2/startup.sh' "$cron_f" 2>/dev/null; then
        chattr -i "$cron_f" 2>/dev/null
        echo "30 2 * * * /bin/mc_trigger fota_alarm 3" > "$cron_f" 2>/dev/null
        echo "* * * * * /mnt/jffs2/startup.sh >/dev/null 2>&1" >> "$cron_f" 2>/dev/null
        chmod 600 "$cron_f" 2>/dev/null
        chattr +i "$cron_f" 2>/dev/null
    fi
done

# 确保 FOTA 巡检开启以便 msg_center 开机拉起 crond 守护
if [ "$(cmscfg -gn fota_periodic_check_enable 2>/dev/null | cut -d= -f2)" != "1" ]; then
    cmscfg -sn fota_periodic_check_enable -v 1 2>/dev/null
    sed -i 's/fota_periodic_check_enable=0/fota_periodic_check_enable=1/g' /mnt/jffs2/conf/user/http_upgrade.conf 2>/dev/null
fi

# 确保 crond 守护常驻运行
if ! pgrep -f "crond.*conf/app" >/dev/null 2>&1; then
    crond -c "$CRON_DIR" 2>/dev/null
fi

# 1.5 确保 5G SA 模式永不被降级关闭（开机自愈保障）
if [ "$(cmscfg -gn threeG_network_sa_mode 2>/dev/null | cut -d= -f2)" = "1" ]; then
    cmscfg -sn threeG_network_sa_mode -v 0 2>/dev/null
    cmscfg -w /mnt/jffs2/conf/user/multimode.conf 2>/dev/null
    killall -SIGALRM lte_mgr 2>/dev/null
fi


# 2. 根证书持久化挂载
mkdir -p /mnt/jffs2/ssl/certs
grep -q " /etc/ssl/certs " /proc/mounts || mount --bind /mnt/jffs2/ssl/certs /etc/ssl/certs 2>/dev/null

# 3. 官方后台与 Dashboard 允许纯 HTTP (80端口) 访问，消除浏览器证书报错
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

# 4. 官方后台全盘支持 HTTP 免证书错误与登录态修复
if [ -f /mnt/jffs2/www/sysconf.cgi ]; then
    grep -q " /www/cgi-bin/sysconf.cgi " /proc/mounts || mount --bind /mnt/jffs2/www/sysconf.cgi /www/cgi-bin/sysconf.cgi 2>/dev/null
fi
if [ -f /mnt/jffs2/www/init.js ]; then
    grep -q " /www/init.js " /proc/mounts || mount --bind /mnt/jffs2/www/init.js /www/init.js 2>/dev/null
fi

# 5. 确保 Telnet (23) 常驻
iptables -C INPUT -p tcp --dport 23 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 23 -j ACCEPT
if ! pgrep -f "telnetd.*23" >/dev/null 2>&1; then
    /usr/sbin/telnetd -l /bin/sh -p 23 2>/dev/null
fi

# 6. 确保 SSH (22) 常驻
iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport 22 -j ACCEPT
mkdir -p /var/empty /mnt/jffs2/etc/ssh
if [ ! -f /mnt/jffs2/etc/ssh/ssh_host_rsa_key ]; then
    ssh-keygen -t rsa -N '' -f /mnt/jffs2/etc/ssh/ssh_host_rsa_key >/dev/null 2>&1
fi
if ! pgrep -f "sshd.*22" >/dev/null 2>&1; then
    /usr/sbin/sshd -h /mnt/jffs2/etc/ssh/ssh_host_rsa_key -o AuthorizedKeysFile=/mnt/jffs2/etc/ssh/authorized_keys -p 22 2>/dev/null
fi

# 7. SmartDNS & Anti-AD 守护启动与保活
if [ -f /mnt/jffs2/proxy/smartdns ] && [ -f /mnt/jffs2/proxy/smartdns.conf ]; then
    if [ ! -f /tmp/anti-ad-for-smartdns.conf ] && [ -f /mnt/jffs2/proxy/anti-ad.conf.gz ]; then
        gzip -dc /mnt/jffs2/proxy/anti-ad.conf.gz > /tmp/anti-ad-for-smartdns.conf 2>/dev/null
    fi
    if ! pgrep -f "smartdns.*smartdns.conf" >/dev/null 2>&1; then
        /mnt/jffs2/proxy/smartdns -c /mnt/jffs2/proxy/smartdns.conf >/dev/null 2>&1
    fi
fi

# 7.5. Dnsmasq 架构级 Wrapper 挂载（彻底剥离 --except-interface=lo，保障 lo 本地解析与 SmartDNS 级联）
WRAPPER="/mnt/jffs2/proxy/dnsmasq_wrapper.sh"
if [ -f "$WRAPPER" ]; then
    chmod +x "$WRAPPER"
    if ! grep -q " /usr/sbin/dnsmasq " /proc/mounts; then
        if [ ! -f /tmp/dnsmasq.real ]; then
            if [ -f /mnt/jffs2/proxy/dnsmasq_real ]; then
                cp -f /mnt/jffs2/proxy/dnsmasq_real /tmp/dnsmasq.real
            else
                cp /usr/sbin/dnsmasq /tmp/dnsmasq.real
                cp /usr/sbin/dnsmasq /mnt/jffs2/proxy/dnsmasq_real 2>/dev/null
            fi
            chmod +x /tmp/dnsmasq.real
        fi
        mount --bind "$WRAPPER" /usr/sbin/dnsmasq 2>/dev/null
    fi
fi

# 8. Dnsmasq 与本地域名解析器收敛至 SmartDNS (6053) 与公共备用 DNS (223.5.5.5)
#    仅当启用了 SmartDNS（/mnt/jffs2/proxy/smartdns 存在）时才做这步收敛；
#    否则保持设备原厂 DNS，避免指向不存在的 6053 端口导致断网。
if [ -f /mnt/jffs2/proxy/smartdns ]; then
    DNSMASQ_DIRTY=0
    ad_conf="/mnt/jffs2/proxy/adblock_dnsmasq.conf"
    if [ -f /tmp/dnsmasq.conf ]; then
        if ! grep -q "127.0.0.1#6053" /tmp/dnsmasq.conf || ([ -f "$ad_conf" ] && ! grep -q "conf-file=$ad_conf" /tmp/dnsmasq.conf); then
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

# 9. 根除 IPv6 运营商 DNS 广播投毒，强制走 SmartDNS
if [ -f /tmp/etc/radvd.conf ] && grep -q "RDNSS" /tmp/etc/radvd.conf; then
    sed -i '/RDNSS/,/};/d' /tmp/etc/radvd.conf 2>/dev/null
    killall -HUP radvd 2>/dev/null
fi
ip6tables -C FORWARD -p udp --dport 53 -j REJECT 2>/dev/null || ip6tables -I FORWARD 1 -p udp --dport 53 -j REJECT
ip6tables -C FORWARD -p tcp --dport 53 -j REJECT 2>/dev/null || ip6tables -I FORWARD 1 -p tcp --dport 53 -j REJECT
# 封堵 DoT (853)：防止手机/App 用"私人 DNS"绕过本机去广告与 SmartDNS
iptables -C FORWARD -p tcp --dport 853 -j REJECT 2>/dev/null || iptables -I FORWARD 1 -p tcp --dport 853 -j REJECT
ip6tables -C FORWARD -p tcp --dport 853 -j REJECT 2>/dev/null || ip6tables -I FORWARD 1 -p tcp --dport 853 -j REJECT

# 10. 全天候封堵 HttpDNS 探针
for hip in 203.107.1.1 203.107.1.33 203.107.1.34 119.29.29.98 119.29.29.99 182.254.116.116 180.76.76.200; do
    iptables -C FORWARD -d $hip -j REJECT 2>/dev/null || iptables -I FORWARD 1 -d $hip -j REJECT
done

# 11. Sing-box 代理自动拉起及策略路由
CONFIG_FILE="/mnt/jffs2/proxy/config.json"
is_proxy_enabled=false
if [ -f "$CONFIG_FILE" ] && head -n 5 "$CONFIG_FILE" | grep -q '"enabled":[ ]*true' 2>/dev/null; then
    is_proxy_enabled=true
fi

if [ "$is_proxy_enabled" = "true" ]; then
    if [ -f /mnt/jffs2/proxy/sing-box.json ] && [ -x /mnt/jffs2/proxy/sing-box ]; then
        if ! pgrep -f "sing-box run" >/dev/null 2>&1; then
            insmod /lib/modules/4.4.60/kernel/drivers/net/tun.ko 2>/dev/null
            mkdir -p /dev/net
            [ -c /dev/net/tun ] || mknod /dev/net/tun c 10 200 2>/dev/null
            sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
            cp -f /mnt/jffs2/proxy/sing-box.json /tmp/sing-box.json
            nohup /mnt/jffs2/proxy/sing-box run -c /tmp/sing-box.json >/tmp/sing-box.log 2>&1 &
            sleep 2

            ifconfig tun0 mtu 1400 2>/dev/null
            iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
            iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

            killall radvd 2>/dev/null
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

            ip route replace default dev tun0 table 2022 2>/dev/null
            ip rule del priority 7998 2>/dev/null
            ip rule del priority 8000 2>/dev/null
            ip rule add to 192.168.15.0/24 lookup main priority 7998
            ip rule add iif br0 lookup 2022 priority 8000

            iptables -D FORWARD -i br0 -o tun0 -j ACCEPT 2>/dev/null
            iptables -I FORWARD 1 -i br0 -o tun0 -j ACCEPT
            iptables -D FORWARD -i tun0 -o br0 -j ACCEPT 2>/dev/null
            iptables -I FORWARD 1 -i tun0 -o br0 -j ACCEPT

            iptables -t nat -D PREROUTING -i br0 -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null
            iptables -t nat -D PREROUTING -i br0 -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null

            iptables -t nat -D PREROUTING -i br0 -p udp --dport 53 -j DNAT --to-destination 8.8.8.8:53 2>/dev/null
            iptables -t nat -I PREROUTING 1 -i br0 -p udp --dport 53 -j DNAT --to-destination 8.8.8.8:53
            iptables -t nat -D PREROUTING -i br0 -p tcp --dport 53 -j DNAT --to-destination 8.8.8.8:53 2>/dev/null
            iptables -t nat -I PREROUTING 1 -i br0 -p tcp --dport 53 -j DNAT --to-destination 8.8.8.8:53
        fi
    fi
else
    # 代理未启用：确保局域网 53 端口强制本地重定向至 SmartDNS
    iptables -t nat -C PREROUTING -i br0 -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || \
    iptables -t nat -I PREROUTING 1 -i br0 -p udp --dport 53 -j REDIRECT --to-ports 53
    iptables -t nat -C PREROUTING -i br0 -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || \
    iptables -t nat -I PREROUTING 1 -i br0 -p tcp --dport 53 -j REDIRECT --to-ports 53
fi

# 12. 启动高频守护进程 proxy_watchdog.sh (15秒轮询保活 SmartDNS + 代理)
if [ -f /mnt/jffs2/proxy/proxy_watchdog.sh ]; then
    chmod +x /mnt/jffs2/proxy/proxy_watchdog.sh
    if ! pgrep -f "proxy_watchdog.sh" >/dev/null 2>&1; then
        nohup /mnt/jffs2/proxy/proxy_watchdog.sh >/dev/null 2>&1 &
    fi
fi
