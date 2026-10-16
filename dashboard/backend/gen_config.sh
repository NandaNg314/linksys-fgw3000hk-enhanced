#!/bin/sh
OUT="/tmp/sing-box.json"

# If flash has a verified configuration, use it
if [ -f "/mnt/jffs2/proxy/sing-box.json" ]; then
    cp -f "/mnt/jffs2/proxy/sing-box.json" "$OUT"
fi

# If OUT still doesn't exist or is invalid, create a fallback minimal config
if [ ! -s "$OUT" ] || ! /mnt/jffs2/proxy/sing-box check -c "$OUT" >/dev/null 2>&1; then
    cat << 'EOF_SB' > "$OUT"
{
  "log": { "level": "warn" },
  "experimental": { "clash_api": { "external_controller": "0.0.0.0:9090" } },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "inet4_address": "172.19.0.1/30",
      "auto_route": false,
      "stack": "system",
      "sniff": true
    },
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "0.0.0.0",
      "listen_port": 2080
    }
  ],
  "outbounds": [
    {
      "type": "selector",
      "tag": "GLOBAL",
      "outbounds": ["direct"],
      "default": "direct"
    },
    { "type": "direct", "tag": "direct" }
  ]
}
EOF_SB
fi
chmod 644 "$OUT"
