#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NOCOLOR='\033[0m'

DEBUG=0
LXC_CONTAINER_NAME="Hiddify-on-LXC"
LXC_IMAGE="ubuntu:22.04"

# 可以修改下面的变量，调整绑定在公网/宿主机 IP 上的端口。
# 但改动可能导致无法申请 SSL 证书。
HTTP_PORT_ON_HOST=80
HTTPS_PORT_ON_HOST=443
DIR_PATH=$(dirname "${BASH_SOURCE[0]}")/

if [ $DEBUG -eq 1 ]; then
  set -e
fi

# 根据发行版安装 LXD
install_lxd() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
      debian)
        echo "检测到 Debian！"
	export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y lxd
        ;;
      ubuntu)
        echo "检测到 Ubuntu！"
	export DEBIAN_FRONTEND=noninteractive
	snap install lxd
	snap refresh lxd
	;;
      fedora)
        echo "检测到 Fedora！"
        dnf upgrade -y
        dnf install -y snapd
        systemctl enable --now snapd.socket
        ln -s /var/lib/snapd/snap /snap
        export PATH="$PATH:/snap/bin"
	snap wait system seed.loaded
        snap install lxd
        ;;
      almalinux|rocky)
        echo "检测到 AlmaLinux/Rocky！"
	dnf install -y epel-release
        dnf upgrade -y
        dnf install -y snapd
        systemctl enable --now snapd.socket
        ln -s /var/lib/snapd/snap /snap
        export PATH="$PATH:/snap/bin"
	snap wait system seed.loaded
        snap install lxd
        ;;
      *)
        echo "当前系统不支持自动安装 LXD：$ID"
	echo "请手动安装 LXD 后重新运行本脚本。"
        exit 1
        ;;
    esac
  else
    echo "无法识别操作系统。"
    echo "请手动安装 LXD 后重新运行本脚本。"
    exit 1
  fi
}

# 拉取 Ubuntu 22.04 镜像并创建容器
setup_container() {
  # 容器是否已存在
  if ! lxc info $LXC_CONTAINER_NAME &> /dev/null; then
    lxc init $LXC_IMAGE $LXC_CONTAINER_NAME
    lxc start $LXC_CONTAINER_NAME
   

    # 配置端口转发
    lxc config device add $LXC_CONTAINER_NAME http     proxy   listen=tcp:0.0.0.0:$HTTP_PORT_ON_HOST connect=tcp:127.0.0.1:80
    lxc config device add $LXC_CONTAINER_NAME https    proxy   listen=tcp:0.0.0.0:$HTTPS_PORT_ON_HOST connect=tcp:127.0.0.1:443
    lxc config device add $LXC_CONTAINER_NAME httpsudp         proxy   listen=udp:0.0.0.0:$HTTPS_PORT_ON_HOST connect=udp:127.0.0.1:443

    # 安装依赖并在容器内执行安装脚本
    lxc exec $LXC_CONTAINER_NAME -- apt-get update
    lxc exec $LXC_CONTAINER_NAME -- apt-get install -y apt-transport-https ca-certificates curl wget gnupg-agent software-properties-common git jq
  
    if [ $DEBUG -eq 1 ]; then
      lxc exec $LXC_CONTAINER_NAME -- bash -x -c "cd /opt && export CREATE_EASYSETUP_LINK='true'; sleep 5; curl https://i.hiddify.com/release|bash -x -s -- --no-gui; exit 0"
    else
      lxc exec $LXC_CONTAINER_NAME -- bash -c "cd /opt && export CREATE_EASYSETUP_LINK='true'; sleep 5;curl https://i.hiddify.com/release|bash -s -- --no-gui; exit 0"
    fi
  else
    echo -e "容器 $LXC_CONTAINER_NAME 已存在。\n"
    echo "1. 如需把 Hiddify Manager 容器的端口映射到公网 IP，请执行："
    echo -e "${GREEN}bash ${DIR_PATH}utils/lxc_ports_to_host.sh${NOCOLOR}\n"
    echo "2. 如需删除之前创建的容器，请执行："
    echo -e "${GREEN}lxc delete $LXC_CONTAINER_NAME --force${NOCOLOR}" 
    exit 1
  fi
}

# 检查容器是否在运行
verify_container() {
  if lxc info $LXC_CONTAINER_NAME | grep -q 'Status: RUNNING'; then
    echo "容器 $LXC_CONTAINER_NAME 已启动并在运行。"
  else
    echo "容器 $LXC_CONTAINER_NAME 启动失败。"
    exit 1
  fi
}


# 主流程

# 检查执行用户
if [ "$EUID" -ne 0 ]; then
  echo "错误：本脚本必须以 root 身份运行。"
  exit 1
fi

if ! which lxd &> /dev/null; then
  echo "未检测到 LXD，即将开始安装……"
  install_lxd 
else
  echo "LXD 已安装。"
fi

if lxd init --dump | grep "networks: \[\]" &> /dev/null; then
  echo "正在以最小配置初始化 LXD……"
  lxd init --minimal
else
  echo "LXD 似乎已初始化。"
fi

setup_container
verify_container

# 打印管理员链接
echo -e "\n\n\n已打印管理员链接。建议优先使用以「https」开头的链接"
lxc exec $LXC_CONTAINER_NAME -- bash -c "cat /opt/hiddify-manager/data/current.json | jq -r '.panel_links[]'"

echo -e "\n\n如需进入容器执行命令，可尝试："
echo "${GREEN}lxc shell $LXC_CONTAINER_NAME${NOCOLOR}"

echo -e "${RED}警告！${NOCOLOR}\n目前 LXC 容器在宿主机上还没有放行端口。每当容器内 Hiddify Manager 使用了新端口，都需要执行 ${GREEN}bash ${DIR_PATH}utils/lxc_ports_to_host.sh${NOCOLOR} 才能在宿主机上访问。"
