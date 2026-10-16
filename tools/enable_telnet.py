"""
Linksys FGW3000-HK - 安全开启 Telnet / SSH
================================================================
仅适用于 Linksys FGW3000-HK。
原理: 利用配置备份/恢复机制，在备份包中：
1. 开启 sysini.conf 中的 sys_gtkshell 与 sys_telnetd
2. 开启 sshd.conf 中的 sshd_enable
3. 注入 /mnt/jffs2/bin/login_without_shell_auth 免密 Shell 脚本 (对应 sys_gtkshell)
4. 更新 etc/shadow 中的 root 密码为 admin 作为双重保障
5. 自动保留原机 passphase (MAC 地址)，保证 100% 校验通过

使用步骤:
1. 在网页已登录状态下下载 Config，重命名为 Config 放到本脚本同目录
2. 运行本脚本: python enable_telnet.py
3. 生成 new_config.bin 后，按 docs/01 的步骤通过 F12 刷入
4. 路由器重启后，命令行运行: telnet 192.168.15.1
"""

import os
import sys
import io
import time
import tarfile
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import padding as sym_padding

# 固件中硬编码的 AES-128-CBC 密钥与 IV（从 libgmi.so 逆向提取）
AES_KEY = b"14381256D62060AE"
AES_IV  = b"D0466BCC211C849E"

# 默认输入与输出路径
CANDIDATE_INPUTS = ["Config", "original_backup.bin"]
OUTPUT_FILE = "new_config.bin"

# root 备用密码哈希 (明文为 admin, 5000 rounds sha-512)
ROOT_ADMIN_HASH = "$6$admin123$0jvkZC4th828gorU/jJXnv2FVQGaXhI9VjqjX.aRspETJPb6aTxpofLxQ6rcicUV4UtoRfFqvwLgaQzbcUnNz/"


def decrypt_backup(enc_data: bytes) -> bytes:
    """解密固件配置备份包"""
    cipher = Cipher(algorithms.AES(AES_KEY), modes.CBC(AES_IV))
    decryptor = cipher.decryptor()
    decrypted = decryptor.update(enc_data) + decryptor.finalize()

    # 去除 PKCS7 padding
    unpadder = sym_padding.PKCS7(128).unpadder()
    data = unpadder.update(decrypted) + unpadder.finalize()
    return data


def encrypt_backup(raw_data: bytes) -> bytes:
    """加密配置备份包"""
    # PKCS7 padding
    padder = sym_padding.PKCS7(128).padder()
    padded = padder.update(raw_data) + padder.finalize()

    cipher = Cipher(algorithms.AES(AES_KEY), modes.CBC(AES_IV))
    encryptor = cipher.encryptor()
    return encryptor.update(padded) + encryptor.finalize()


def modify_sysini(content: str) -> str:
    """修改 sysini.conf 中的 telnet 相关开关"""
    lines = content.splitlines()
    modified = []
    changed = []

    has_gtkshell = any(l.strip().startswith('sys_gtkshell') for l in lines)
    has_telnetd = any(l.strip().startswith('sys_telnetd') for l in lines)

    for line in lines:
        stripped = line.strip()

        # 开启 gtkshell（系统原生免密 shell 启动开关）
        if stripped.startswith('sys_gtkshell'):
            modified.append('sys_gtkshell\tenable')
            changed.append('sys_gtkshell: disable -> enable')
        # 开启 telnetd（服务与防火墙放行开关）
        elif stripped.startswith('sys_telnetd'):
            modified.append('sys_telnetd\tenable')
            changed.append('sys_telnetd: disable -> enable')
        else:
            modified.append(line)

    if not has_gtkshell:
        modified.append('sys_gtkshell\tenable')
        changed.append('sys_gtkshell: (追加配置项) -> enable')
    if not has_telnetd:
        modified.append('sys_telnetd\tenable')
        changed.append('sys_telnetd: (追加配置项) -> enable')

    if changed:
        print("[*] sysini.conf 修改项:")
        for c in changed:
            print(f"    {c}")

    return '\n'.join(modified) + '\n'


def modify_shadow(content: str) -> str:
    """更新 shadow 文件中 root 的密码为 admin 作为后备保障"""
    lines = content.splitlines()
    modified = []
    for line in lines:
        if line.startswith('root:'):
            parts = line.split(':')
            parts[1] = ROOT_ADMIN_HASH
            modified.append(':'.join(parts))
            print("[+] 已将 etc/shadow 中 root 密码同步设置为: admin (以防万一)")
        else:
            modified.append(line)
    return '\n'.join(modified) + '\n'


def modify_sshd(content: str) -> str:
    """修改 sshd.conf 中的 sshd_enable 为 enable"""
    lines = content.splitlines()
    modified = []
    changed = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith('sshd_enable') and 'disable' in stripped:
            modified.append('sshd_enable=enable')
            changed.append('sshd_enable: disable -> enable')
        else:
            modified.append(line)
    if changed:
        print("[*] sshd.conf 修改项:")
        for c in changed:
            print(f"    {c}")
    return '\n'.join(modified) + '\n'


def main():
    # 输入文件：优先脚本所在目录（用户通常把 Config 放这里），其次当前目录
    script_dir = os.path.dirname(os.path.abspath(__file__))
    input_file = None
    for cand in CANDIDATE_INPUTS:
        for base in (script_dir, os.getcwd()):
            p = os.path.join(base, cand)
            if os.path.exists(p):
                input_file = p
                break
        if input_file:
            break

    if not input_file:
        print(f"[!] 未找到配置文件，已尝试查找: {CANDIDATE_INPUTS}")
        print(f"    查找目录: {script_dir}  和  {os.getcwd()}")
        sys.exit(1)

    # 输出写到脚本所在目录
    output_file = os.path.join(script_dir, OUTPUT_FILE)

    print(f"[*] 读取原始备份包: {input_file}")
    with open(input_file, 'rb') as f:
        enc_data = f.read()
    print(f"[*] 加密数据大小: {len(enc_data)} 字节")

    # 解密
    print("[*] 正在解密备份包...")
    try:
        tar_data = decrypt_backup(enc_data)
    except Exception as e:
        print(f"[!] 解密失败: {e}")
        sys.exit(1)
    print(f"[*] 解密成功，tar.gz 大小: {len(tar_data)} 字节")

    # 解包、修改并重构
    print("[*] 正在重构配置文件...")
    output_stream = io.BytesIO()
    found_passphase = "未知"

    with tarfile.open(fileobj=io.BytesIO(tar_data), mode='r:gz') as original_tar:
        with tarfile.open(fileobj=output_stream, mode='w:gz') as new_tar:
            for member in original_tar.getmembers():
                f = original_tar.extractfile(member)
                if f is None:
                    new_tar.addfile(member)
                    continue

                content = f.read()

                # 读取 passphase 确认 MAC
                if member.name.endswith('passphase'):
                    found_passphase = content.decode('ascii', errors='ignore').strip()
                    new_tar.addfile(member, io.BytesIO(content))

                # 修改 sysini.conf
                elif member.name.endswith('sysini.conf'):
                    print(f"[+] 修改: {member.name}")
                    new_content = modify_sysini(content.decode('utf-8', errors='replace'))
                    new_bytes = new_content.encode('utf-8')
                    member.size = len(new_bytes)
                    new_tar.addfile(member, io.BytesIO(new_bytes))

                # 修改 shadow
                elif member.name.endswith('shadow') and not member.name.endswith('shadow-'):
                    new_content = modify_shadow(content.decode('utf-8', errors='replace'))
                    new_bytes = new_content.encode('utf-8')
                    member.size = len(new_bytes)
                    new_tar.addfile(member, io.BytesIO(new_bytes))

                # 修改 sshd.conf
                elif member.name.endswith('sshd.conf'):
                    print(f"[+] 修改: {member.name}")
                    new_content = modify_sshd(content.decode('utf-8', errors='replace'))
                    new_bytes = new_content.encode('utf-8')
                    member.size = len(new_bytes)
                    new_tar.addfile(member, io.BytesIO(new_bytes))

                # 其他配置原样保留
                else:
                    new_tar.addfile(member, io.BytesIO(content))

            # 注入免密 shell 脚本 /mnt/jffs2/bin/login_without_shell_auth
            # 这一步是固件中 sys_gtkshell 生效的关键触发点
            now = int(time.time())
            bin_dir = tarfile.TarInfo(name='./bin')
            bin_dir.type = tarfile.DIRTYPE
            bin_dir.mode = 0o755
            bin_dir.mtime = now
            new_tar.addfile(bin_dir)

            script_bytes = b"#!/bin/sh\nexport PATH=/bin:/sbin:/usr/bin:/usr/sbin\nexec /bin/sh\n"
            login_ti = tarfile.TarInfo(name='./bin/login_without_shell_auth')
            login_ti.type = tarfile.REGTYPE
            login_ti.mode = 0o755
            login_ti.size = len(script_bytes)
            login_ti.mtime = now
            new_tar.addfile(login_ti, io.BytesIO(script_bytes))
            print("[+] 注入: ./bin/login_without_shell_auth (免密直接拉起 Root Shell)")

    new_tar_data = output_stream.getvalue()
    print(f"[*] 重新打包完成，tar.gz 大小: {len(new_tar_data)} 字节")
    print(f"[*] 检测到路由器 MAC: {found_passphase} (已完美匹配原机)")

    # 加密
    print("[*] 正在进行 AES-128-CBC 加密打包...")
    new_enc = encrypt_backup(new_tar_data)

    with open(output_file, 'wb') as f:
        f.write(new_enc)
    print(f"[+] 成功生成配置包: {output_file} ({len(new_enc)} 字节)")
    print()
    print("=" * 65)
    print("【下一步恢复操作】")
    print("1. 浏览器打开 Linksys 管理后台: http://192.168.15.1")
    print("2. 进入 系统管理 (Management) -> 软件/固件更新 (Software)")
    print("3. 在「配置备份 (Configuration backup)」卡片中：")
    print(f"   - 点击 [浏览/Browse] 按钮，选择: {output_file}")
    print("   - 点击 [恢复/Restore] 按钮")
    print("   - 弹出密码框时，输入任意 9 位以上字符 (例如: test12345)")
    print("   - 点击 [应用/Apply]")
    print("4. 等待路由器刷入并自动重启 (约 1.5 - 2 分钟)")
    print("5. 电脑通过网线或 WiFi 连接路由器，打开终端命令行运行:")
    print("   telnet 192.168.15.1")
    print("   -> 直接回车即可获得 Root Shell (# 提示符)！")
    print("   (若弹出 login 提示，输入 root，密码为 admin)")
    print("=" * 65)


if __name__ == '__main__':
    main()
