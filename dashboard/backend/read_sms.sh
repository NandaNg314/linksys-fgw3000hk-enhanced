#!/bin/sh
# ==============================================================================
# Linksys FGW3000 SMS Reader (Modem HTTP Pipeline + Telnet Failover)
# ==============================================================================

MODEM_IP="10.10.10.3"
HTTP_PORT="55102"
LOCK_DIR="/tmp/.read_sms_lock"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_AGE=$(find /tmp -maxdepth 1 -name ".read_sms_lock" -mmin +0.2 2>/dev/null)
    if [ -n "$LOCK_AGE" ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null
        mkdir "$LOCK_DIR" 2>/dev/null || exit 0
    else
        [ -f /tmp/inbox.json ] && cat /tmp/inbox.json
        exit 0
    fi
fi

trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

JSON=""

# 1. Primary: Modem HTTP CGI (includes SIM + ME + Modem /data/ims_inbox.json)
RAW_HTTP=$(curl -s -m 4 "http://$MODEM_IP:$HTTP_PORT/cgi-bin/sms" 2>/dev/null)
if echo "$RAW_HTTP" | grep -q '{"ok":true'; then
    JSON=$(echo "$RAW_HTTP" | grep '{"ok":true' | tr -d '\r' | tail -n 1)
fi

# 2. Fallback 1: Telnet 55101
if [ -z "$JSON" ]; then
    RAW_TELNET=$(expect -c "
        set timeout 6
        spawn telnet $MODEM_IP 55101
        expect \"#\"
        send \"perl /data/parse_sms.pl\r\"
        expect \"#\"
        send \"exit\r\"
        expect eof
    " 2>/dev/null | grep '{"ok":true' | tr -d '\r' | tail -n 1)
    if [ -n "$RAW_TELNET" ]; then
        JSON="$RAW_TELNET"
        expect -c "
            set timeout 3
            spawn telnet $MODEM_IP 55101
            expect \"#\"
            send \"busybox httpd -p $MODEM_IP:$HTTP_PORT -h /data/www\r\"
            expect \"#\"
            send \"exit\r\"
            expect eof
        " >/dev/null 2>&1 &
    fi
fi

# 3. Fallback 2: Telnet 55100
if [ -z "$JSON" ]; then
    RAW_TELNET0=$(expect -c "
        set timeout 6
        spawn telnet $MODEM_IP 55100
        expect \"#\"
        send \"perl /data/parse_sms.pl\r\"
        expect \"#\"
        send \"exit\r\"
        expect eof
    " 2>/dev/null | grep '{"ok":true' | tr -d '\r' | tail -n 1)
    if [ -n "$RAW_TELNET0" ]; then
        JSON="$RAW_TELNET0"
    fi
fi

if [ -n "$JSON" ]; then
    echo "$JSON" > /tmp/inbox.json.tmp && mv -f /tmp/inbox.json.tmp /tmp/inbox.json
    echo "$JSON"
else
    if [ -f /tmp/inbox.json ]; then
        cat /tmp/inbox.json
    else
        echo '{"ok":true,"count":0,"next_index":0,"messages":[]}' > /tmp/inbox.json
        cat /tmp/inbox.json
    fi
fi