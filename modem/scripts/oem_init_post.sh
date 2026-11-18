ip addr add 192.168.254.3 peer 192.168.254.7/32 dev mhi_swip0 2>/dev/null
ip rule add to 10.10.10.7/32 lookup main pref 1 2>/dev/null
ip route replace 10.10.10.7/32 dev mhi_swip0 scope link src 10.10.10.3 2>/dev/null
ip rule add to 192.168.254.7/32 lookup main pref 1 2>/dev/null
ip route replace 192.168.254.7/32 dev mhi_swip0 scope link src 192.168.254.3 2>/dev/null
iptables -t nat -I POSTROUTING 1 -o mhi_swip0 -j ACCEPT 2>/dev/null
iptables -I INPUT 1 -i mhi_swip0 -j ACCEPT 2>/dev/null
mkdir -p /data/www/cgi-bin
if ! pgrep -f 'busybox httpd.*55102' >/dev/null 2>&1; then
    busybox httpd -p 10.10.10.3:55102 -h /data/www
fi
if ! pgrep -f 'telnetd.*55101' >/dev/null 2>&1; then
    /usr/lib/busybox/usr/sbin/telnetd -l /bin/sh -b 0.0.0.0:55101 -K &
fi
if [ -x /data/ims_sip ] && ! pgrep -f '^/data/ims_sip$' >/dev/null 2>&1; then
    nohup /data/ims_sip >/dev/null 2>&1 &
fi
