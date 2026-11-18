#!/bin/sh
TARGET_TYPE="$1"
ARG2="$2"

if [ -z "$TARGET_TYPE" ]; then
    echo '{"success":false,"ok":false,"error":"缺少删除参数"}'
    exit 1
fi

MODEM_IP="10.10.10.3"
HTTP_PORT="55102"
LOCK_DIR="/tmp/.read_sms_lock"

WAIT_CNT=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    WAIT_CNT=$((WAIT_CNT + 1))
    if [ "$WAIT_CNT" -ge 20 ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null
        mkdir "$LOCK_DIR" 2>/dev/null || break
        break
    fi
    usleep 200000 2>/dev/null || sleep 1
done
trap 'rm -rf "$LOCK_DIR"' EXIT INT TERM

JSON=""
RAW_HTTP=$(curl -s -m 10 "http://$MODEM_IP:$HTTP_PORT/cgi-bin/delete_sms?target=$TARGET_TYPE&arg2=$ARG2" 2>/dev/null)
if echo "$RAW_HTTP" | grep -q '{"ok":true'; then
    JSON=$(echo "$RAW_HTTP" | grep '{"ok":true' | tr -d '\r' | tail -n 1)
fi

if [ -z "$JSON" ]; then
    DEC_TARGET=$(echo "$TARGET_TYPE" | sed -e 's/%3A/:/g' -e 's/%3a/:/g' -e 's/%2C/,/g' -e 's/%2c/,/g' -e 's/%20/ /g')
    DEC_ARG2=$(echo "$ARG2" | sed -e 's/%3A/:/g' -e 's/%3a/:/g' -e 's/%2C/,/g' -e 's/%2c/,/g' -e 's/%20/ /g')
    for P in 55101 55100; do
        RAW_TELNET=$(expect -c "
            set timeout 12
            spawn telnet $MODEM_IP $P
            expect -re \"#\"
            send \"sh /data/del_sms.sh \\\"$DEC_TARGET\\\" \\\"$DEC_ARG2\\\"\r\"
            expect -re \"#\"
            send \"exit\r\"
            expect eof
        " 2>/dev/null | grep '{"ok":true' | tr -d '\r' | tail -n 1)
        if [ -n "$RAW_TELNET" ]; then
            JSON="$RAW_TELNET"
            break
        fi
    done
fi

rm -rf "$LOCK_DIR" 2>/dev/null
if [ -n "$JSON" ]; then
    echo "$JSON" > /tmp/inbox.json.tmp && mv -f /tmp/inbox.json.tmp /tmp/inbox.json
    echo "$JSON" | sed 's/{"ok":true/{"success":true,"ok":true/'
else
    /mnt/jffs2/read_sms.sh | sed 's/{"ok":true/{"success":true,"ok":true/'
fi