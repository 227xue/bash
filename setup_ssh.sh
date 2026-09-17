```bash
#!/bin/bash
set -e

echo "=========================================="
echo "       VPS SSH + BBR 初始化脚本"
echo "=========================================="

# 必须 root
if [ "$EUID" -ne 0 ]; then
    echo "错误：请使用 root 用户执行此脚本！"
    exit 1
fi


########################################
# 1. 获取 SSH 公钥
########################################

echo
echo "[1/8] 请粘贴 SSH 公钥"
echo "支持 ssh-ed25519 / ssh-rsa / ecdsa-sha2-*"
echo

read -r PUB_KEY

if [ -z "$PUB_KEY" ]; then
    echo "错误：公钥不能为空！"
    exit 1
fi

# 基础格式检查
if ! echo "$PUB_KEY" | grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[^ ]+) [A-Za-z0-9+/=]+( .*)?$'; then
    echo "错误：公钥格式看起来不正确！"
    echo "请确认复制的是 .pub 文件中的完整一行。"
    exit 1
fi

echo "[+] 公钥格式检查通过"


########################################
# 2. 随机 SSH 端口
########################################

NEW_PORT=$((RANDOM % 25001 + 40000))

echo
echo "[2/8] 随机生成 SSH 新端口：$NEW_PORT"


########################################
# 3. 写入 authorized_keys
########################################

echo
echo "[3/8] 配置 SSH 公钥"

mkdir -p /root/.ssh
chmod 700 /root/.ssh

touch /root/.ssh/authorized_keys

if ! grep -qxF "$PUB_KEY" /root/.ssh/authorized_keys; then
    echo "$PUB_KEY" >> /root/.ssh/authorized_keys
    echo "[+] 公钥已添加"
else
    echo "[+] 公钥已经存在，跳过"
fi

chmod 600 /root/.ssh/authorized_keys


########################################
# 4. 备份 SSH 配置
########################################

echo
echo "[4/8] 备份 SSH 配置"

BACKUP_FILE="/etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)"

cp /etc/ssh/sshd_config "$BACKUP_FILE"

echo "[+] 备份完成：$BACKUP_FILE"


########################################
# 5. 修改 SSH 配置
########################################

echo
echo "[5/8] 修改 SSH 配置"


# 删除旧 Port 配置
sed -i '/^[[:space:]]*#\?[[:space:]]*Port[[:space:]]/d' /etc/ssh/sshd_config

echo "Port $NEW_PORT" >> /etc/ssh/sshd_config


# 密码登录关闭
if grep -qE '^[[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]]' /etc/ssh/sshd_config; then
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication no/' /etc/ssh/sshd_config
else
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
fi


# ChallengeResponseAuthentication
if grep -qE '^[[:space:]]*#?[[:space:]]*ChallengeResponseAuthentication[[:space:]]' /etc/ssh/sshd_config; then
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*ChallengeResponseAuthentication[[:space:]].*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
else
    echo "ChallengeResponseAuthentication no" >> /etc/ssh/sshd_config
fi


# 公钥认证
if grep -qE '^[[:space:]]*#?[[:space:]]*PubkeyAuthentication[[:space:]]' /etc/ssh/sshd_config; then
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*PubkeyAuthentication[[:space:]].*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
else
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
fi


# Root 允许密钥登录，但禁止密码
if grep -qE '^[[:space:]]*#?[[:space:]]*PermitRootLogin[[:space:]]' /etc/ssh/sshd_config; then
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*PermitRootLogin[[:space:]].*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
else
    echo "PermitRootLogin prohibit-password" >> /etc/ssh/sshd_config
fi


########################################
# SSH 配置语法检查
########################################

echo
echo "[+] 检查 SSH 配置..."

sshd -t

echo "[+] SSH 配置语法正确"


########################################
# 6. UFW
########################################

echo
echo "[6/8] 检查 UFW"

if command -v ufw >/dev/null 2>&1; then

    UFW_STATUS=$(ufw status | head -n 1)

    if echo "$UFW_STATUS" | grep -qi "active"; then

        echo "[+] UFW 当前已经启用"

        ufw allow "$NEW_PORT/tcp"

        echo "[+] 已放行 SSH 新端口：$NEW_PORT"

    else

        echo "[!] UFW 当前未启用"
        echo "[!] 不自动启用 UFW，避免影响后续节点/Docker部署"

    fi

else

    echo "[!] 未安装 UFW"
    echo "[!] 跳过防火墙配置"

fi


########################################
# 7. BBR / BBRv3
########################################

echo
echo "[7/8] 检查 BBR"


# 加载 tcp_bbr
modprobe tcp_bbr 2>/dev/null || true


# 检查当前内核支持的拥塞控制算法
AVAILABLE_CC=$(sysctl -n net.ipv4.tcp_allowed_congestion_control 2>/dev/null || true)

echo
echo "当前内核支持的拥塞控制算法："
echo "$AVAILABLE_CC"


# 判断是否存在 bbr3
if echo "$AVAILABLE_CC" | grep -qw "bbr3"; then

    echo
    echo "[+] 检测到 BBRv3！"

    sysctl -w net.ipv4.tcp_congestion_control=bbr3

    # 持久化
    cat >/etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr3
EOF

    sysctl --system >/dev/null

    CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control)

    echo "[+] BBRv3 已启用"
    echo "[+] 当前拥塞控制算法：$CURRENT_CC"

else

    echo
    echo "[!] 当前内核没有检测到 bbr3"
    echo "[!] 不强行修改内核"
    echo
    echo "当前可用算法："
    echo "$AVAILABLE_CC"

    # 如果有普通 BBR，则启用 BBR
    if echo "$AVAILABLE_CC" | grep -qw "bbr"; then

        sysctl -w net.ipv4.tcp_congestion_control=bbr

        cat >/etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

        sysctl --system >/dev/null

        echo "[+] 已启用普通 BBR"
        echo "[!] 如需 BBRv3，需要更换/升级支持 BBRv3 的 Linux 内核"

    else

        echo "[!] 当前内核连 BBR 都不支持"
        echo "[!] 跳过 BBR 配置"

    fi

fi


########################################
# 8. Reload SSH
########################################

echo
echo "[8/8] 应用 SSH 配置"

if systemctl reload ssh 2>/dev/null; then

    echo "[+] SSH reload 成功"

elif systemctl reload sshd 2>/dev/null; then

    echo "[+] SSH reload 成功"

else

    echo "[!] SSH reload 失败"
    echo "[!] 当前 SSH 配置没有被应用"

    exit 1

fi


########################################
# 最终检查
########################################

echo
echo "=========================================="
echo "             初始化完成"
echo "=========================================="

echo
echo "SSH 新端口       : $NEW_PORT"
echo "密码登录         : 已禁用"
echo "Root 密钥登录    : 已允许"
echo "SSH 配置备份     : $BACKUP_FILE"

echo
echo "TCP 拥塞控制："
sysctl net.ipv4.tcp_congestion_control

echo
echo "默认队列："
sysctl net.core.default_qdisc

echo
echo "监听端口："
ss -lntp | grep ":$NEW_PORT " || true

echo
echo "=========================================="
echo "请从 FinalShell 新建 SSH 连接测试："
echo "服务器：$(hostname -I | awk '{print $1}')"
echo "端口：$NEW_PORT"
echo "用户：root"
echo "认证：SSH 私钥"
echo "=========================================="
```
