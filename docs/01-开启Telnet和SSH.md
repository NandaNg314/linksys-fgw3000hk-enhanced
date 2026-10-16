# 01 · 开启 Telnet / SSH（详细步骤）

> 适用：**Linksys FGW3000-HK**（高通 IPQ8072A + 骁龙 X55）。
> 目标：在原厂固件下**永久开启 Telnet(23) / SSH(22)**。

---

## 一、原理速览

固件内置了 Telnet/SSH，只是开关被关。本项目通过「官方配置备份/恢复」机制，
把 `sys_telnetd` / `sys_gtkshell` / `sshd_enable` 改成 `enable` 再刷回。
详见 [03-原理与常见问题](03-原理与常见问题.md)。

> ⚠️ **务必用你自己机器生成的包**：配置包含本机标识（MAC），换机刷入会校验失败。

---

## 二、准备工作

- 电脑用网线接 FGW3000-HK 的 **LAN 口**
- 浏览器能打开并登录 `http://192.168.15.1`
- 安装 Python 3 依赖：
  ```bash
  pip install cryptography
  ```

---

## 三、第 1 步：导出配置备份（得到 `Config`）

### 情况 A：后台能看到「配置备份 / 恢复」按钮

1. 登录 `http://192.168.15.1` → 系统管理 → 软件（Software）→「配置备份」卡片。
2. 点 **保存/备份**，弹窗里输入 **9~64 位任意密码**（如 `test12345`），应用。
3. 浏览器下载到一个**无扩展名**的文件，通常名为 `Config`。

### 情况 B：后台看不到按钮（部分固件隐藏）

在已登录页面按 **F12** → Console（首次粘贴需输入 `allow pasting`），粘贴：

```javascript
(function () {
  var phase = "test12345";                                  // 9~64 位备份密码（随便设）
  var enc = encryption(pubkey, phase);                      // RSA 加密
  $.ajax({
    url: "/cgi-bin/sysconf.cgi",
    type: "POST",
    data: { page: "ajax.asp", passphase: enc, action: "download_cfg", time: Date.now() },
    cache: false,
    success: function (res) {
      if (res === "successful") location.replace("/backupConfig/Config");  // 触发下载
      else alert("导出失败，返回: " + res);
    },
    error: function (xhr) { alert("请求错误，状态: " + xhr.status); }
  });
})();
```

浏览器会自动下载 `Config`。

### 放置文件

把下载的文件**重命名为 `Config`（无扩展名）**，放到 `tools/enable_telnet.py` **同目录**。

---

## 四、第 2 步：生成 `new_config.bin`

```bash
python tools/enable_telnet.py
```

正常输出类似：

```
[*] 读取原始备份包: Config
[*] 正在解密备份包...
[+] 修改: ./conf/user/sysini.conf
    sys_gtkshell: disable -> enable
    sys_telnetd: disable -> enable
[+] 已将 etc/shadow 中 root 密码同步设置为: admin
[+] 修改: ./conf/user/sshd.conf
    sshd_enable: disable -> enable
[+] 注入: ./bin/login_without_shell_auth (免密直接拉起 Root Shell)
[*] 检测到路由器 MAC: XX:XX:XX:XX:XX:XX (已完美匹配原机)
[+] 成功生成配置包: new_config.bin (xxxxx 字节)
```

同目录生成 **`new_config.bin`**。

---

## 五、第 3 步：F12 刷入并重启

1. 在 `http://192.168.15.1` 已登录页面按 **F12** → Console。
2. 粘贴下面**整行**，网页左上角生成黄色文件框：
   ```javascript
   var i = document.createElement("input"); i.type = "file"; i.id = "my_cfg"; i.style = "position:fixed;top:30px;left:30px;z-index:999999;font-size:20px;background:#ff0;padding:15px;border:3px solid red;"; document.body.appendChild(i);
   ```
   → 点击黄框，选择 `new_config.bin`。
3. 粘贴刷入代码，回车：
   ```javascript
   $("#sub-page-wrapper").load(
     NewFormAction("control_panel_sw.asp", "request"),
     function() {
       var f = document.getElementById("my_cfg");
       var file = f ? f.files[0] : null;
       if (!file) { alert("请先选择 new_config.bin！"); return; }
       var c = $("#confirm_code").val();
       alert("获取到有效令牌: " + c + "，开始刷入！");
       var ep = encryption(pubkey, "test123451");
       var a1 = "confirm_code=" + c;
       var a2 = "&action=upload_cfg";
       var a3 = "&upload_passphase=" + ep;
       var a4 = "&upload_passphase_len=10";
       var a5 = "&timestamp=" + Date.now();
       var act = a1 + a2 + a3 + a4 + a5;
       var off = "confirm_code=".length;
       var cnt = act.substr(off);
       if (cnt[0] != "&") { cnt = cnt.substr(33); } else { cnt = cnt.substr(1); }
       var md = $.md5(cnt);
       var u1 = "/cgi-bin/sysconf.cgi";
       var u2 = "?page=control_panel_sw.asp";
       var u3 = "&ui_component=" + md;
       var u4 = "&" + act;
       var fd = new FormData();
       fd.append("confirm_code", c);
       fd.append("file", file);
       $.ajax({
         url: u1 + u2 + u3 + u4, type: "POST", data: fd,
         processData: false, contentType: false,
         success: function(res) { alert("刷入成功！路由器即将灭灯重启（约2分钟）！"); },
         error: function(xhr) { alert("已提交，状态: " + xhr.status + "，请看指示灯！"); }
       });
     }
   );
   ```
4. 路由器**灭灯自动重启**（约 1.5~2 分钟），期间别断电。
   - 若没反应：把上面代码**再执行一遍**（可安全重复）。

---

## 六、验证成功

```bash
telnet 192.168.15.1      # 端口 23，免密，直入 root（推荐）
ssh root@192.168.15.1    # 端口 22，root / admin
```

- Windows 若提示无 telnet：控制面板 → 启用或关闭 Windows 功能 → 勾选 **Telnet Client**。
- 网页免登录控制台：`http://192.168.15.1/weblog/cmd.cgi?cmd=ifconfig`

---

## 七、FAQ

- **Q：`new_config.bin` 能给别人用吗？** 不能。内含原机 MAC，换机校验失败。
- **Q：需要手动输 MAC 吗？** 不需要。标识是固件导出时自动写入的，脚本原样保留。
- **Q：控制台报 `pubkey is not defined`？** 说明不在官方页面或未登录，先登录再操作。
- **Q：刷完连不上？** 确认同网段、已完全重启、`ping 192.168.15.1` 通。

> 下一步：刷入 Web 控制台 → [02-部署与配置](02-部署与配置.md)
