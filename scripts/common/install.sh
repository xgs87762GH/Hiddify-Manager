#!/bin/bash
source utils.sh
SCRIPT_DIR="$(cd "$(dirname -- "$0")" && pwd)"
remove_package apache2 needrestart needrestart-session
install_package apt-transport-https apt-utils at bash-completion build-essential ca-certificates cron curl default-libmysqlclient-dev dnsutils gawk git gnupg-agent gnupg2 iproute2 iptables jq less libev-dev libevdev2 libssl-dev locales lsb-release lsof pkg-config qrencode software-properties-common sudo ubuntu-keyring wget whiptail
activate_python_venv
#python -m pip config set global.index-url https://pypi.org/simple > /dev/null
# remove_package resolvconf
# rm /etc/resolv.conf
# ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf



groupadd -f hiddify-common
usermod -aG hiddify-common root

# rm /run/resolvconf/interface/*
#echo "nameserver 8.8.8.8" >/etc/resolv.conf
#echo "nameserver 1.1.1.1" >>/etc/resolv.conf
#echo "nameserver 8.8.8.8" >/etc/resolvconf/resolv.conf.d/base
#echo "nameserver 1.1.1.1" >>/etc/resolvconf/resolv.conf.d/base
#resolvconf -u
sudo systemctl unmask --now systemd-resolved.service
systemctl enable --now systemd-resolved >/dev/null 2>&1 || true

# 安装 change_dns.py 所需依赖
install_pypi_package pyyaml > /dev/null
if ! nslookup google.com &> /dev/null; then
    warning "DNS 不可用。"
    ./change_dns.py 8.8.8.8 1.1.1.1
fi


ln -sf $(pwd)/sysctl.conf /etc/sysctl.d/hiddify.conf

if [ "${MODE}" != "docker" ];then
  sysctl --system > /dev/null
fi

# 是否仅使用 IPv4 由面板设置决定（环境变量优先）。
if [[ -z "$ONLY_IPV4" ]]; then
    ONLY_IPV4=$(hconfig only_ipv4 2>/dev/null)
fi

# 内核可能已关闭 IPv6（ipv6.disable=1 或 sysctl disable_ipv6=1）：
# 此时没有可切换的项，必须保持关闭。
if [[ ! -d /proc/sys/net/ipv6 ]] || [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" == 1 ]]; then
    ONLY_IPV4=true
    KERNEL_IPV6=false
else
    KERNEL_IPV6=true
fi

# 先尝试开启 IPv6，若实际不通则回退为仅 IPv4。
if [[ "$ONLY_IPV4" != true ]]; then
    sysctl -w net.ipv6.conf.all.disable_ipv6=0
    sysctl -w net.ipv6.conf.default.disable_ipv6=0
    sysctl -w net.ipv6.conf.lo.disable_ipv6=0

    curl --connect-timeout 1 -s http://ipv6.google.com 2>&1 >/dev/null
    if [ $? != 0 ]; then
        ONLY_IPV4=true
    fi
fi

INT_STAT=0
INT_STAT_STR='启用'
if [[ "$ONLY_IPV4" == true ]]; then
    INT_STAT=1
    INT_STAT_STR="禁用"
fi

declare -a excluded_interfaces=("warp" "lo")

if [[ "$KERNEL_IPV6" == true ]]; then
for interface_name in $(ip link | awk -F': ' '$2 ~ /^[[:alnum:]]+$/ {print $2}'); do
    if [[ " ${excluded_interfaces[*]} " =~ " ${interface_name} " ]]; then
        continue
    fi

    # 针对当前网卡设置 IPv6 开关
    sysctl -q -w "net.ipv6.conf.$interface_name.disable_ipv6=$INT_STAT"

    if [ $? -eq 0 ]; then
        echo "$interface_name 的 IPv6 已${INT_STAT_STR}"
    else
        echo "${INT_STAT_STR} $interface_name 的 IPv6 时失败"
    fi
done
fi

bash google-bbr.sh > /dev/null


# 重启后自动重新应用配置；每日执行一次清理任务
echo "@reboot root /opt/hiddify-manager/scripts/install.sh --no-gui --no-log >> /opt/hiddify-manager/data/log/reboot.log 2>&1" >/etc/cron.d/hiddify_reinstall_on_reboot
mv /etc/cron.d/hiddify_daily_memory_release /etc/cron.d/hiddify_daily > /dev/null 2>&1 || true
echo "@daily root /opt/hiddify-manager/scripts/common/daily_actions.sh >> /opt/hiddify-manager/data/log/daily_actions.log 2>&1" >/etc/cron.d/hiddify_daily
service cron reload >/dev/null 2>&1 || true

if [ "${MODE}" != "docker" ];then
  localectl set-locale LANG=C.UTF-8 >/dev/null 2>&1 || true
fi

update-locale LANG=C.UTF-8 >/dev/null 2>&1 || true

# 直接覆盖而不是追加，避免重复安装时产生多行 sudoers 规则。
# 面板 run_commander.py 调用的是：sudo <venv>/bin/python .../commander.py <args>
#（不只是可执行文件本身）。两种形式都要放行，否则点击"应用"会卡在 "command not allowed"。
_commander=/opt/hiddify-manager/scripts/common/commander.py
_panel_py=/opt/hiddify-manager/.venv313/bin/python
if [ ! -x "$_panel_py" ]; then
  if [ -x /opt/hiddify-manager/.venv/bin/python ]; then
    _panel_py=/opt/hiddify-manager/.venv/bin/python
  elif [ -x /opt/hiddify-manager/.venv310/bin/python ]; then
    _panel_py=/opt/hiddify-manager/.venv310/bin/python
  fi
fi
{
  echo "hiddify-panel ALL=(root) NOPASSWD: ${_commander}"
  echo "hiddify-panel ALL=(root) NOPASSWD: ${_panel_py} ${_commander} *"
} >/etc/sudoers.d/hiddify
chmod 440 /etc/sudoers.d/hiddify
unset _commander _panel_py

# 安装 hiddify 命令行及补全
chmod +x /opt/hiddify-manager/scripts/hiddify
ln -sf /opt/hiddify-manager/scripts/hiddify /usr/bin/hiddify
mkdir -p /etc/bash_completion.d /etc/profile.d
ln -sf /opt/hiddify-manager/scripts/hiddify-completion.bash /etc/bash_completion.d/hiddify
ln -sf /opt/hiddify-manager/scripts/hiddify-profile.sh /etc/profile.d/hiddify.sh
if [ -f "$HOME/.bashrc" ] && ! grep -qF 'hiddify-completion.bash' "$HOME/.bashrc"; then
    echo '[ -f /opt/hiddify-manager/scripts/hiddify-completion.bash ] && . /opt/hiddify-manager/scripts/hiddify-completion.bash' >>"$HOME/.bashrc"
fi

# Ubuntu 24 通常没有 rpcbind：直接 `systemctl disable` 会返回 1，
# 导致安装虽成功却把"常用工具"标成红色。只处理确实存在的单元。
if systemctl cat rpcbind.socket >/dev/null 2>&1; then
  systemctl disable --now rpcbind.socket >/dev/null 2>&1 || true
fi
if systemctl cat rpcbind.service >/dev/null 2>&1; then
  systemctl disable --now rpcbind >/dev/null 2>&1 || true
fi
