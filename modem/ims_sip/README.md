# Modem-Side 5G IMS SIP / SMS Daemon (`ims_sip`)

本目录包含运行于 Linksys FGW3000-HK 内部高通 SDX55 基带（`10.10.10.3`，ARMv7 Linux）上的静态 Go 守护进程源码。

## 设计原理

- **单 PDN 硬件加速零损耗**：主路由（AP `192.168.15.1`）保持 `APN_Multiple_PDN_Enable=0`，仅建立 `cid=1` 数据承载走 IPQ8074A NSS 硬件卸载加速，避免 AP 侧多 QMAP 通道破坏硬件加速导致限速。
- **基带本地直连 QRTR + `rmnet_ipa0`**：`ims_sip` 直接在 SDX55 基带内部通过 `AF_QIPCRTR (42)` 访问 QMI WDS / UIM 服务：
  1. 自动维护 `ims` Profile 3（IPv6 + `im_cn_flag=1`）并通过 `WDS_BIND_MUX_DATA_PORT` + `WDS_START_NETWORK_INTERFACE` 绑定到基带本地 `rmnet_data0@rmnet_ipa0`；
  2. 通过 QMI UIM `0x0034` 完成 USIM AKA (`AKAv1-MD5`) 鉴权，走纯 UDP 5060 向运营商 P-CSCF / S-CSCF 完成 `SIP REGISTER`（携带 `+g.3gpp.smsip`）；
  3. 实时解码 `SIP MESSAGE` 内的 3GPP `RP-DATA` / `SMS-DELIVER` PDU（支持 7-bit / UCS-2 及长短信拼接），立即回发上行 `RP-ACK` 终结核心网重传，落盘至 `/data/ims_inbox.json`（保留最新 20 条，日志上限 256KB 自动截断）；
  4. 每 60 秒通过纯 QRTR 巡检承载状态与 IPv6 `/64` 前缀漂移，夜间基站释放或重建会话时自动重拨重注册。

## 交叉编译（生成无依赖 ARMv7 静态二进制）

需要 Go 1.21+ 环境：

```bash
# Linux / macOS / Git Bash
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -ldflags="-s -w" -o ims_sip main.go
```

```powershell
# Windows PowerShell
$env:CGO_ENABLED="0"; $env:GOOS="linux"; $env:GOARCH="arm"; $env:GOARM="7"
go build -trimpath -ldflags="-s -w" -o ims_sip main.go
```

## 部署路径（基带 `10.10.10.3`）

- 二进制路径：`/data/ims_sip`（`chmod +x /data/ims_sip`）
- 状态文件：`/tmp/ims_sip.status`、`/tmp/ims_sip.log`
- 控制接口：`/data/www/cgi-bin/ims_sip_ctl?action=status|ensure|restart|stop`
- 开机自启：由基带 `/data/oem_init_post.sh` 启动，并由主路由 `/mnt/jffs2/startup.sh` 跨端探活兜底。
