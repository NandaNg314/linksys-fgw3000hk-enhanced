#!/bin/sh
echo "Content-Type: application/json; charset=utf-8"
echo "Access-Control-Allow-Origin: *"
echo ""

# URL decode helper
urldecode() {
    printf '%b' "${1//%/\\x}"
}

ACTION=$(echo "$QUERY_STRING" | sed -n 's/.*action=\([^&]*\).*/\1/p')
ACTION=$(urldecode "$ACTION")

STATUS_FILE="/tmp/modem_status.json"
INBOX_FILE="/tmp/inbox.json"

case "$ACTION" in
    status)
        if [ ! -s "$STATUS_FILE" ]; then
            # Query directly if cache missing
            csq=$(timeout -t 3 /mnt/jffs2/atcmd.exp 'AT+CSQ' 2>/dev/null | grep '+CSQ:' | sed -n 's/.*+CSQ: *\([0-9,]*\).*/\1/p' | tr -d '\r')
            cops=$(timeout -t 3 /mnt/jffs2/atcmd.exp 'AT+COPS?' 2>/dev/null | grep '+COPS:' | sed -n 's/.*"\([^"]*\)".*/\1/p' | tr -d '\r')
            [ -z "$csq" ] && csq="31,99"
            [ -z "$cops" ] && cops="CHINA MOBILE CMCC"
            pid=$(pgrep -f "sms_forwarder.sh" | head -n 1)
            [ -z "$pid" ] && pid=0
            echo "{\"cpin\":\"READY\",\"csq\":\"${csq}\",\"cops\":\"${cops}\",\"daemon_pid\":${pid},\"inbox_count\":0}" > "$STATUS_FILE"
        fi
        cat "$STATUS_FILE"
        exit 0
        ;;

    inbox|"")
        if [ -f "$INBOX_FILE" ]; then
            cat "$INBOX_FILE"
        else
            echo '{"ok":true,"messages":[]}'
        fi
        exit 0
        ;;

    send)
        TO=$(echo "$QUERY_STRING" | sed -n 's/.*to=\([^&]*\).*/\1/p')
        MSG=$(echo "$QUERY_STRING" | sed -n 's/.*msg=\([^&]*\).*/\1/p')
        TO=$(urldecode "$TO")
        MSG=$(urldecode "$MSG")

        if [ -z "$TO" ] || [ -z "$MSG" ]; then
            echo '{"ok":false,"error":"Missing to or msg"}'
            exit 0
        fi

        OUT=$(/mnt/jffs2/sms_send.sh "$TO" "$MSG" 2>&1)
        if echo "$OUT" | grep -q "成功"; then
            echo '{"ok":true,"message":"Sent successfully"}'
        else
            ESC_OUT=$(printf "%s" "$OUT" | awk '{gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); printf "%s", $0}')
            echo "{\"ok\":false,\"error\":\"${ESC_OUT}\"}"
        fi
        exit 0
        ;;

    delete)
        IDX=$(echo "$QUERY_STRING" | sed -n 's/.*index=\([^&]*\).*/\1/p')
        IDX=$(urldecode "$IDX")
        if [ -n "$IDX" ]; then
            timeout -t 5 /mnt/jffs2/atcmd.exp "AT+CMGD=${IDX}" >/dev/null 2>&1
            # Refresh inbox
            rm -f "$INBOX_FILE"
            echo '{"ok":true,"message":"Deleted"}'
        else
            echo '{"ok":false,"error":"Missing index"}'
        fi
        exit 0
        ;;

    *)
        echo '{"ok":false,"error":"Unknown action"}'
        exit 0
        ;;
esac
