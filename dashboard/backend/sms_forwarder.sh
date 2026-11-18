#!/bin/sh
# ==============================================================================
# Linksys FGW3000 SMS Realtime Multi-Channel Forwarder Daemon (v2.3 Rock Solid)
# ==============================================================================

CONF="/mnt/jffs2/conf/user/sms_forward.json"
FLASH_SEEN="/mnt/jffs2/conf/user/.seen_sms_sigs"
MEM_SEEN="/tmp/.seen_sms_sigs"
HISTORY_FILE="/mnt/jffs2/sms_history.log"
LOG_FILE="/tmp/sms_forwarder.log"

log() {
    if [ -f "$LOG_FILE" ] && [ $(wc -c < "$LOG_FILE" 2>/dev/null || echo 0) -gt 512000 ]; then
        tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

sync_seen_to_flash() {
    if [ $(wc -l < "$MEM_SEEN" 2>/dev/null || echo 0) -gt 500 ]; then
        tail -n 300 "$MEM_SEEN" > "$MEM_SEEN.tmp" 2>/dev/null && mv -f "$MEM_SEEN.tmp" "$MEM_SEEN"
    fi
    cp -f "$MEM_SEEN" "$FLASH_SEEN.tmp" 2>/dev/null && mv -f "$FLASH_SEEN.tmp" "$FLASH_SEEN"
}

extract_code() {
    local raw="$1"
    echo "$raw" | grep -o -E '([0-9]{4,6})' | head -n 1
}

send_push() {
    local sender="$1"
    local date="$2"
    local content="$3"
    local code="$4"
    [ -z "$code" ] && code=$(extract_code "$content")

    [ -f "$CONF" ] || return 0

    local global_enabled
    global_enabled=$(grep -o '"enabled":[ ]*[^,}]*' "$CONF" | awk -F: '{print $2}' | tr -d ' "')
    [ "$global_enabled" = "false" ] && return 0

    local title="短信来自 $sender"
    [ -n "$code" ] && title="【$code】验证码 · 来自 $sender"

    log "收到新短信: 来自 $sender, 验证码: [${code:-无}], 内容: $content"

    local any_enabled=0
    local any_net_ok=0
    local any_net_fail=0

    # ==================== 1. 电子邮箱 SMTP 转发 ====================
    local email_enabled smtp_host smtp_port smtp_user smtp_pass mail_from mail_to
    email_enabled=$(grep -o '"email_enabled":[ ]*[^,}]*' "$CONF" | awk -F: '{print $2}' | tr -d ' "')
    smtp_host=$(grep -o '"smtp_host":[ ]*"[^"]*"' "$CONF" | awk -F: '{print $2}' | tr -d ' "')
    [ -z "$smtp_host" ] && smtp_host="smtp.qq.com"
    smtp_port=$(grep -o '"smtp_port":[ ]*[^,}]*' "$CONF" | awk -F: '{print $2}' | tr -d ' "')
    [ -z "$smtp_port" ] && smtp_port="465"
    smtp_user=$(grep -o '"smtp_user":[ ]*"[^"]*"' "$CONF" | awk -F: '{print $2}' | tr -d ' "')
    smtp_pass=$(grep -o '"smtp_pass":[ ]*"[^"]*"' "$CONF" | awk -F: '{print $2}' | tr -d ' "')
    mail_from=$(grep -o '"mail_from":[ ]*"[^"]*"' "$CONF" | awk -F: '{print $2}' | tr -d ' "')
    [ -z "$mail_from" ] && mail_from="$smtp_user"
    mail_to=$(grep -o '"mail_to":[ ]*"[^"]*"' "$CONF" | awk -F: '{print $2}' | tr -d ' "')

    if [ "$email_enabled" = "true" ] && [ -n "$smtp_user" ] && [ -n "$smtp_pass" ] && [ -n "$mail_to" ]; then
        any_enabled=1
        local b64_subj eml_file code_html
        b64_subj=$(printf "%s" "$title" | openssl base64 -A 2>/dev/null)
        eml_file="/tmp/send_sms.eml"
        code_html=""
        [ -n "$code" ] && code_html="<div style=\"margin:16px 0;padding:18px;background:#f0f7ff;border:1px solid rgba(0,113,227,0.15);border-radius:12px;text-align:center;\"><span style=\"font-size:12px;color:#0071E3;font-weight:600;letter-spacing:1px;\">提取验证码</span><div style=\"font-size:36px;font-weight:700;color:#0071E3;letter-spacing:6px;margin-top:6px;font-family:ui-monospace,Menlo,monospace;\">$code</div></div>"

        cat > "$eml_file" << EOF
From: "FGW3000 短信中心" <$mail_from>
To: <$mail_to>
Date: $(date "+%a, %d %b %Y %H:%M:%S +0800")
Message-ID: <$(date +%s).cpe@qq.com>
MIME-Version: 1.0
Subject: =?UTF-8?B?$b64_subj?=
Content-Type: text/html; charset=UTF-8

<div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:540px;margin:20px auto;padding:24px;background:#ffffff;border:1px solid #e5e5ea;border-radius:16px;color:#1d1d1f;">
  <div style="display:flex;align-items:center;gap:10px;margin-bottom:16px;">
    <div style="width:36px;height:36px;border-radius:8px;background:#0071E3;display:flex;align-items:center;justify-content:center;color:#fff;font-weight:bold;font-size:18px;">L</div>
    <div>
      <h3 style="margin:0;color:#1d1d1f;font-size:16px;">$title</h3>
      <p style="margin:2px 0 0;color:#86868b;font-size:12px;">Linksys FGW3000 5G CPE 实时推送</p>
    </div>
  </div>
  $code_html
  <table style="width:100%;font-size:13px;border-collapse:collapse;margin-top:18px;">
    <tr><td style="padding:7px 0;color:#86868b;width:70px;">发件号码</td><td style="padding:7px 0;font-weight:600;font-family:ui-monospace,Menlo,monospace;">$sender</td></tr>
    <tr><td style="padding:7px 0;color:#86868b;">接收时间</td><td style="padding:7px 0;font-variant-numeric:tabular-nums;">$date</td></tr>
    <tr><td style="padding:7px 0;color:#86868b;vertical-align:top;">完整正文</td><td style="padding:7px 0;line-height:1.5;">$content</td></tr>
  </table>
  <hr style="border:none;border-top:1px solid #f0f0f2;margin:20px 0 10px;">
  <p style="margin:0;font-size:11px;color:#a1a1a6;text-align:center;">由 Linksys FGW3000 (China Mobile 4G/5G) 自动发送</p>
</div>
EOF
        if curl -k -s -m 8 --connect-timeout 4 --ssl-reqd \
            --url "smtps://$smtp_host:$smtp_port" \
            --login-options 'AUTH=LOGIN' \
            --user "$smtp_user:$smtp_pass" \
            --mail-from "$mail_from" \
            --mail-rcpt "$mail_to" \
            --upload-file "$eml_file" >/dev/null 2>&1; then
            any_net_ok=1
            log "邮件推送至 $mail_to 成功"
        else
            any_net_fail=1
            log "邮件推送至 $mail_to 失败(网络或超时)"
        fi
        rm -f "$eml_file"
    fi

    # ==================== 2. PushPlus 微信推送通道 ====================
    local pp_enabled pushplus_token
    pp_enabled=$(grep -o '"pushplus_enabled":[ ]*[^,}]*' "$CONF" | awk -F: '{print $2}' | tr -d ' "')
    pushplus_token=$(grep -o '"pushplus_token":[ ]*"[^"]*"' "$CONF" | awk -F: '{print $2}' | tr -d ' "')

    if [ "$pp_enabled" = "true" ] && [ -n "$pushplus_token" ]; then
        any_enabled=1
        local code_b=""
        [ -n "$code" ] && code_b="<br><b>提取验证码：</b><span style='color:#0071E3;font-size:24px;font-weight:bold;'>$code</span>"
        local pp_title pp_content pp_body resp
        pp_title=$(printf "%s" "$title" | tr -d '\r\n')
        pp_content=$(printf "发件人：%s<br>接收时间：%s%s<hr>正文：%s" "$sender" "$date" "$code_b" "$content" | tr -d '\r\n')
        pp_body="{\"token\":\"$pushplus_token\",\"title\":\"$pp_title\",\"content\":\"$pp_content\",\"template\":\"html\"}"
        if resp=$(curl -s -m 6 --connect-timeout 4 -X POST 'http://www.pushplus.plus/send' \
            -H 'Content-Type: application/json' \
            -d "$pp_body" 2>&1); then
            any_net_ok=1
            log "PushPlus 微信推送结果: $resp"
        else
            any_net_fail=1
            log "PushPlus 微信推送失败: $resp"
        fi
    fi

    # ==================== 3. Bark 推送通道 (iOS) ====================
    local bark_enabled bark_url
    bark_enabled=$(grep -o '"bark_enabled":[ ]*[^,}]*' "$CONF" | awk -F: '{print $2}' | tr -d ' "')
    bark_url=$(grep -o '"bark_url":[ ]*"[^"]*"' "$CONF" | awk -F: '{print $2}' | tr -d ' "')

    if [ "$bark_enabled" = "true" ] && [ -n "$bark_url" ]; then
        any_enabled=1
        bark_url=$(echo "$bark_url" | sed 's|/*$||')
        local b_title b_content
        b_title=$(printf "%s" "$title" | od -An -tx1 | tr ' ' '%')
        b_content=$(printf "%s" "$content" | od -An -tx1 | tr ' ' '%')
        if curl -k -s -m 6 --connect-timeout 4 "$bark_url/$b_title/$b_content?group=CPE短信" >/dev/null 2>&1; then
            any_net_ok=1
            log "已发送 Bark 推送"
        else
            any_net_fail=1
            log "Bark 推送失败"
        fi
    fi

    # ==================== 4. Telegram Bot ====================
    local tg_enabled tg_token tg_chat
    tg_enabled=$(grep -o '"tg_enabled":[ ]*[^,}]*' "$CONF" | awk -F: '{print $2}' | tr -d ' "')
    tg_token=$(grep -o '"tg_bot_token":[ ]*"[^"]*"' "$CONF" | awk -F: '{print $2}' | tr -d ' "')
    tg_chat=$(grep -o '"tg_chat_id":[ ]*"[^"]*"' "$CONF" | awk -F: '{print $2}' | tr -d ' "')

    if [ "$tg_enabled" = "true" ] && [ -n "$tg_token" ] && [ -n "$tg_chat" ]; then
        any_enabled=1
        local tg_text
        tg_text=$(printf "🔔 %s\n\n%s" "$title" "$content")
        if curl -k -s -m 6 --connect-timeout 4 "https://api.telegram.org/bot$tg_token/sendMessage" \
            -d "chat_id=$tg_chat" --data-urlencode "text=$tg_text" >/dev/null 2>&1; then
            any_net_ok=1
            log "已发送 Telegram 推送"
        else
            any_net_fail=1
            log "Telegram 推送失败"
        fi
    fi

    # ==================== 5. Custom Webhook ====================
    local webhook_enabled webhook
    webhook_enabled=$(grep -o '"webhook_enabled":[ ]*[^,}]*' "$CONF" | awk -F: '{print $2}' | tr -d ' "')
    webhook=$(grep -o '"webhook_url":[ ]*"[^"]*"' "$CONF" | awk -F: '{print $2}' | tr -d ' "')

    if [ "$webhook_enabled" = "true" ] && [ -n "$webhook" ]; then
        any_enabled=1
        local wh_json="/tmp/wh_push.json"
        cat > "$wh_json" << EOF
{"sender":"$sender","date":"$date","content":"$content","code":"$code"}
EOF
        if curl -k -s -m 6 --connect-timeout 4 -X POST -H "Content-Type: application/json" -d @"$wh_json" "$webhook" >/dev/null 2>&1; then
            any_net_ok=1
            log "已发送 Webhook 推送"
        else
            any_net_fail=1
            log "Webhook 推送失败"
        fi
        rm -f "$wh_json"
    fi

    if [ "$any_enabled" -eq 0 ] || [ "$any_net_ok" -eq 1 ]; then
        echo "[$date] 来自: $sender | 验证码: [${code:-无}] | 内容: $content" >> "$HISTORY_FILE"
        return 0
    fi
    return 1
}

mkdir -p /mnt/jffs2/conf/user
if [ -f "$FLASH_SEEN" ]; then
    cp -f "$FLASH_SEEN" "$MEM_SEEN" 2>/dev/null
else
    touch "$MEM_SEEN"
fi

should_ignore() {
    local content="$1"
    if [ -f "$CONF" ]; then
        local user_kw
        user_kw=$(grep -o '"ignore_keywords":[ ]*"[^"]*"' "$CONF" | sed -n 's/.*"ignore_keywords":[ ]*"\([^"]*\)".*/\1/p')
        if [ -n "$user_kw" ]; then
            local old_ifs="$IFS"
            IFS=','
            for k in $user_kw; do
                k=$(echo "$k" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                if [ -n "$k" ]; then
                    case "$content" in
                        *"$k"*)
                            IFS="$old_ifs"
                            return 0
                            ;;
                    esac
                fi
            done
            IFS="$old_ifs"
        fi
    fi
    return 1
}

log "=== SMS 实时多渠道推送转发守护进程启动 (v2.3 防吞信/闪存优化版) ==="

while true; do
    /mnt/jffs2/read_sms.sh >/dev/null 2>&1

    if [ -f "/tmp/inbox.json" ]; then
        DIRTY_SEEN=0
        grep -o '{"index":[0-9]*[^}]*}' /tmp/inbox.json | while read -r msg; do
            SENDER=$(echo "$msg" | sed -n 's/.*"sender":"\([^"]*\)".*/\1/p')
            DATE=$(echo "$msg" | sed -n 's/.*"date":"\([^"]*\)".*/\1/p')
            CODE=$(echo "$msg" | sed -n 's/.*"code":"\([^"]*\)".*/\1/p')
            CONTENT=$(echo "$msg" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p')

            MSG_SIG="${DATE}_${SENDER}_${CONTENT}"

            if [ -n "$MSG_SIG" ] && ! grep -Fq "$MSG_SIG" "$MEM_SEEN" 2>/dev/null; then
                if should_ignore "$CONTENT"; then
                    echo "$MSG_SIG" >> "$MEM_SEEN"
                    sync_seen_to_flash
                    log "命中免打扰规则，跳过推送: 来自 $SENDER, 内容: $CONTENT"
                    echo "[$DATE] 来自: $SENDER | [已静音免打扰] | 内容: $CONTENT" >> "$HISTORY_FILE"
                else
                    if send_push "$SENDER" "$DATE" "$CONTENT" "$CODE"; then
                        echo "$MSG_SIG" >> "$MEM_SEEN"
                        sync_seen_to_flash
                    else
                        log "全部推送通道失败，保留未读签名待下次网络恢复补推: $SENDER ($DATE)"
                    fi
                fi
            fi
        done

        TOTAL_COUNT=$(grep -o '"count":[0-9]*' /tmp/inbox.json | head -n 1 | cut -d: -f2)
        if [ -n "$TOTAL_COUNT" ] && [ "$TOTAL_COUNT" -ge 6 ]; then
            log "模组存储槽位已达到 $TOTAL_COUNT 条，触发防截断安全自愈..."
            grep -o '{"index":[0-9]*[^}]*}' /tmp/inbox.json | head -n 4 | while read -r old_msg; do
                IDX=$(echo "$old_msg" | sed -n 's/.*"indices":"\([0-9,-]*\)".*/\1/p')
                [ -z "$IDX" ] && IDX=$(echo "$old_msg" | sed -n 's/.*"index":\([0-9]*\).*/\1/p')
                ST=$(echo "$old_msg" | sed -n 's/.*"storage":"\([^"]*\)".*/\1/p')
                O_SENDER=$(echo "$old_msg" | sed -n 's/.*"sender":"\([^"]*\)".*/\1/p')
                O_DATE=$(echo "$old_msg" | sed -n 's/.*"date":"\([^"]*\)".*/\1/p')
                O_CONTENT=$(echo "$old_msg" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p')
                O_SIG="${O_DATE}_${O_SENDER}_${O_CONTENT}"
                if grep -Fq "$O_SIG" "$MEM_SEEN" 2>/dev/null; then
                    /mnt/jffs2/delete_sms.sh "$IDX" "$ST" >/dev/null 2>&1
                fi
            done
            log "防截断安全自愈执行完毕"
        fi
    fi

    sleep 8
done