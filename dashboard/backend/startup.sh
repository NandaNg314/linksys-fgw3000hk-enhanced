#!/bin/sh
# ==============================================================================
ip link set dev rmnet_mhi_sw0 arp off up 2>/dev/null; ip addr add 10.10.10.7 peer 10.10.10.3/32 dev rmnet_mhi_sw0 2>/dev/null; ip route replace 10.10.10.3 dev rmnet_mhi_sw0 proto kernel scope link src 10.10.10.7 2>/dev/null; ip addr add 192.168.254.7 peer 192.168.254.3/32 dev rmnet_mhi_sw0 2>/dev/null; ip route replace 192.168.254.3 dev rmnet_mhi_sw0 proto kernel scope link src 192.168.254.7 2>/dev/null; ip link set dev rmnet_mhi0 up 2>/dev/null; ip link set dev rmnet_data0 up 2>/dev/null
grep -q " /sbin/reboot " /proc/mounts || mount --bind /mnt/jffs2/block_reboot.sh /sbin/reboot 2>/dev/null
grep -q " /bin/lte_mgr " /proc/mounts || mount --bind /mnt/jffs2/lte_mgr_csps /bin/lte_mgr 2>/dev/null
grep -q " /bin/reboot_sdx55.sh " /proc/mounts || mount --bind /mnt/jffs2/no_reboot_sdx55.sh /bin/reboot_sdx55.sh 2>/dev/null

# === qnicorn KFC 关闭（kfc_mode=0 kfc_qmap=0）：让 QMAP 退回标准格式，避免 5G SA 下行被丢 ===
grep -q " /etc/data/qnicorn_config.xml " /proc/mounts 2>/dev/null || mount --bind /mnt/jffs2/qnicorn_config.xml /etc/data/qnicorn_config.xml 2>/dev/null

# === lte_mgr 异常告警检测（只记告警不永久 SIGSTOP，避免断网后无法自愈） ===
if [ ! -f /tmp/.lte_freeze_done ]; then
    (
        for W in 12 30 50; do
            sleep $W 2>/dev/null || sleep 12
            ERRS=$(grep -c "QCM_DMS_SERVICE_ERR" /tmp/lte_mgr/LCMServer.log 2>/dev/null || echo 0)
            R12=$(dmesg 2>/dev/null | grep -c "qrtr_sendmsg.*-12")
            if [ "$ERRS" -gt 5 ] || [ "$R12" -gt 3 ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] t=$W errs=$ERRS qrtr-12=$R12 (no SIGSTOP)" >> /tmp/lte_freeze.log
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [LTE_MGR_WARN] t=$W errs=$ERRS qrtr-12=$R12" >> /mnt/jffs2/wan_events.log
                break
            fi
        done
        touch /tmp/.lte_freeze_done
    ) &
fi
echo SYSTEM > /sys/bus/msm_subsys/devices/subsys0/restart_level

# 模组开机黄金期自动固化注入与 USIM 自愈守护
if [ ! -f /tmp/.modem_injected ]; then
    (
        for i in $(seq 1 30); do
            if ping -c 1 -W 1 10.10.10.3 >/dev/null 2>&1; then
                /mnt/jffs2/deploy_to_modem.sh >/tmp/deploy_to_modem.log 2>&1
                touch /tmp/.modem_injected
                break
            fi
            sleep 2
        done
    ) &
fi

# 5G/4G 数据网络自愈编排与巡检（开机初始化 + 每分钟非阻塞健康检查）
if [ ! -f /tmp/.net_boot_started ]; then
    touch /tmp/.net_boot_started
    (
        sleep 30
        timeout -t 150 /mnt/jffs2/net_orchestrator.sh --boot >/tmp/net_orchestrator.log 2>&1
        touch /tmp/.net_boot_done
    ) &
elif [ -f /tmp/.net_boot_done ]; then
    (
        timeout -t 25 /mnt/jffs2/net_orchestrator.sh --check >/tmp/net_orchestrator_check.log 2>&1
    ) &
fi

# Flash-persistent on /mnt/jffs2/startup.sh
# ==============================================================================

# 0. 核心路由基准规则保障
ip rule show | grep -q "lookup local" || ip rule add lookup local pref 0 2>/dev/null
ip rule show | grep -q "lookup main" || ip rule add lookup main pref 32766 2>/dev/null
ip rule show | grep -q "lookup default" || ip rule add lookup default pref 32767 2>/dev/null
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
iptables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
ip6tables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
ip6tables -t mangle -I FORWARD 1 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# 0.5 蜂窝状态机与 LED 指示灯自愈（必须同时持有有效 IPv4 且默认路由存在，严禁仅凭 UP 假亮绿灯）
WAN_V4=$(ip -4 addr show dev rmnet_data0 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -n 1)
if [ -n "$WAN_V4" ] && ip -4 route show default 2>/dev/null | grep -q "rmnet_data0"; then
    if [ "$(cmscfg -gn CMServerState 2>/dev/null | cut -d= -f2)" != "5" ]; then
        cmscfg -sn CMServerState -v 5 2>/dev/null
        cmscfg -sn SIM_Presence -v 1 2>/dev/null
        cmscfg -sn SIM_PINStatus -v 0 2>/dev/null
        echo xxxx0100xx > /dev/led_gpio 2>/dev/null
    fi
fi

# 1. 确保 Crontab 自动持久化注入与不可篡改保障（已移除 02:30 fota_alarm）
CRON_DIR="/mnt/jffs2/conf/app"
mkdir -p "$CRON_DIR"
for cron_f in "$CRON_DIR/crontab.tab" "$CRON_DIR/root"; do
    if [ ! -f "$cron_f" ] || ! grep -q '/mnt/jffs2/startup.sh' "$cron_f" 2>/dev/null || grep -q 'fota_alarm' "$cron_f" 2>/dev/null; then
        chattr -i "$cron_f" 2>/dev/null
        echo "* * * * * /mnt/jffs2/startup.sh >/dev/null 2>&1" > "$cron_f" 2>/dev/null
        echo "30 4 * * 0 /mnt/jffs2/proxy/update_anti_ad.sh >/dev/null 2>&1" >> "$cron_f" 2>/dev/null
        chmod 600 "$cron_f" 2>/dev/null
        chattr +i "$cron_f" 2>/dev/null
    fi
done

# 保留 fota_periodic_check_enable=1 以便 msg_center 开机拉起 crond（实际 FOTA 由 http_upgrade.conf fota_enable=0 禁用）
if [ "$(cmscfg -gn fota_periodic_check_enable 2>/dev/null | cut -d= -f2)" != "1" ]; then
    cmscfg -sn fota_periodic_check_enable -v 1 2>/dev/null
    sed -i 's/fota_periodic_check_enable=0/fota_periodic_check_enable=1/g' /mnt/jffs2/conf/user/http_upgrade.conf 2>/dev/null
fi

# 确保 crond 守护常驻运行
if ! pgrep -f "crond.*conf/app" >/dev/null 2>&1; then
    crond -c "$CRON_DIR" 2>/dev/null
fi

# 1.5 确保 5G SA 模式永不被降级关闭（只修正配置并记录，不发 SIGALRM lte_mgr）
if [ "$(cmscfg -gn threeG_network_sa_mode 2>/dev/null | cut -d= -f2)" = "1" ]; then
    cmscfg -sn threeG_network_sa_mode -v 0 2>/dev/null
    cmscfg -w /mnt/jffs2/conf/user/multimode.conf 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [SA_GUARD] Reset threeG_network_sa_mode=0 (no SIGALRM)" >> /mnt/jffs2/wan_events.log
fi

# 2. 根证书持久化挂载
mkdir -p /mnt/jffs2/ssl/certs
grep -q " /etc/ssl/certs " /proc/mounts || mount --bind /mnt/jffs2/ssl/certs /etc/ssl/certs 2>/dev/null

# 2.5 修复 curl 默认读不到 CA 根证书
CA_FILE=/etc/ssl/certs/ca-certificates.crt
if [ -f "$CA_FILE" ]; then
    export CURL_CA_BUNDLE="$CA_FILE"
    export SSL_CERT_FILE="$CA_FILE"
    echo "export CURL_CA_BUNDLE=$CA_FILE" > /tmp/.cacert.env
    echo "export SSL_CERT_FILE=$CA_FILE" >> /tmp/.cacert.env
fi

# 3. 官方后台与 Dashboard 允许纯 HTTP (80端口) 访问
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

# 5. 确保 Telnet (23) 仅对内网 br0 放行（先加 br0 再删宽泛/WAN 规则防失联）
iptables -C INPUT -i br0 -p tcp --dport 23 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i br0 -p tcp --dport 23 -j ACCEPT
iptables -D INPUT -p tcp --dport 23 -j ACCEPT 2>/dev/null
iptables -D INPUT -i rmnet_data0 -p tcp --dport 23 -j ACCEPT 2>/dev/null
if ! pgrep -f "telnetd.*23" >/dev/null 2>&1; then
    /usr/sbin/telnetd -l /bin/sh -p 23 2>/dev/null
fi

# 6. 确保 SSH (22) 仅对内网 br0 放行（先加 br0 再删宽泛规则防失联）
iptables -C INPUT -i br0 -p tcp --dport 22 -j ACCEPT 2>/dev/null || iptables -I INPUT 1 -i br0 -p tcp --dport 22 -j ACCEPT
iptables -D INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null
mkdir -p /var/empty /mnt/jffs2/etc/ssh
if [ ! -f /mnt/jffs2/etc/ssh/ssh_host_rsa_key ]; then
    ssh-keygen -t rsa -N '' -f /mnt/jffs2/etc/ssh/ssh_host_rsa_key >/dev/null 2>&1
fi
if ! pgrep -f "sshd.*22" >/dev/null 2>&1; then
    /usr/sbin/sshd -h /mnt/jffs2/etc/ssh/ssh_host_rsa_key -o AuthorizedKeysFile=/mnt/jffs2/etc/ssh/authorized_keys -o PermitRootLogin=yes -o PasswordAuthentication=yes -p 22 2>/dev/null
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

# 7.5. Dnsmasq 架构级 Wrapper 挂载
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

# 8. Dnsmasq 与本地域名解析器收敛（使用 flock 与 proxy_watchdog.sh 互斥，避免竞态重杀）
if [ -f /mnt/jffs2/proxy/smartdns ] && ! pgrep -f "proxy_watchdog.sh" >/dev/null 2>&1; then
    (
        flock -x 8
        DNSMASQ_DIRTY=0
        ad_conf="/mnt/jffs2/proxy/adblock_dnsmasq.conf"
        if [ -f /tmp/dnsmasq.conf ]; then
            if ! grep -q "127.0.0.1#6053" /tmp/dnsmasq.conf || \
               ! grep -q "223.5.5.5" /tmp/dnsmasq.conf || \
               ! grep -q "strict-order" /tmp/dnsmasq.conf || \
               ([ -f "$ad_conf" ] && ! grep -q "conf-file=$ad_conf" /tmp/dnsmasq.conf); then
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
            /usr/sbin/dnsmasq -i br0 --conntrack --bind-interfaces -K -N -C /tmp/dnsmasq.conf --pid-file=/var/run/dnsmasq.pid 2>/dev/null 8>&-
        fi
    ) 8>/var/run/dnsmasq_cfg.lock
fi

# 9. 根除 IPv6 运营商 DNS 广播投毒，强制走 SmartDNS；封堵 DoT 853
if [ -f /tmp/etc/radvd.conf ] && grep -q "RDNSS" /tmp/etc/radvd.conf; then
    sed -i '/RDNSS/,/};/d' /tmp/etc/radvd.conf 2>/dev/null
    killall -HUP radvd 2>/dev/null
fi
if [ -f /tmp/etc/radvd.conf ] && ! pgrep -f "radvd" >/dev/null 2>&1; then
    /usr/sbin/radvd -C /tmp/etc/radvd.conf 2>/dev/null
fi
ip6tables -C FORWARD -p udp --dport 53 -j REJECT 2>/dev/null || ip6tables -I FORWARD 1 -p udp --dport 53 -j REJECT
ip6tables -C FORWARD -p tcp --dport 53 -j REJECT 2>/dev/null || ip6tables -I FORWARD 1 -p tcp --dport 53 -j REJECT
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

# 13. 启动 WoL 远程开机服务
if [ -x /mnt/jffs2/wol/wol_daemon.sh ]; then
    /mnt/jffs2/wol/wol_daemon.sh >/dev/null 2>&1
fi
sleep 2
if [ -x /mnt/jffs2/wol/reverse_tunnel_daemon.sh ]; then
    /mnt/jffs2/wol/reverse_tunnel_daemon.sh >/dev/null 2>&1
fi

# 14. 启动短信实时推送转发服务
if [ -x /mnt/jffs2/sms_forwarder.sh ]; then
    if ! pgrep -f sms_forwarder.sh >/dev/null 2>&1; then
        nohup /mnt/jffs2/sms_forwarder.sh >/dev/null 2>&1 &
    fi
fi

# 15. 5G IMS SMS receiver daemon (runs locally on modem 10.10.10.3)
for p in $(pgrep -f "^/mnt/jffs2/ims_sip" 2>/dev/null); do
    kill "$p" 2>/dev/null
done
if ping -c 1 -W 1 10.10.10.3 >/dev/null 2>&1; then
    wget -qO- -T 4 "http://10.10.10.3:55102/cgi-bin/ims_sip_ctl?action=ensure" >/dev/null 2>&1 &
fi
