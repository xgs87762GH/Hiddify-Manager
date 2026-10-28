#!/bin/sh
if [ "$(id -u)" -ne 0 ]; then
    echo '本脚本必须以 root 身份运行' >&2
    exit 1
fi

checkOS() {
    # 支持的发行版列表
    #supported_distros=("Ubuntu" "Debian" "Fedora" "CentOS" "Arch")
    supported_distros=("Ubuntu")
    # 获取发行版名称与版本号
    if [[ -f "/etc/os-release" ]]; then
        source "/etc/os-release"
        distro_name=$NAME
        distro_version=$VERSION_ID
    else
        echo "无法识别当前发行版。"
        exit 1
    fi
    # 检查发行版是否受支持
    if [[ " ${supported_distros[@]} " =~ " ${distro_name} " ]]; then
        echo "当前系统为 ${distro_name} ${distro_version}"
        : #空操作
    else
        # 以红色输出错误信息
        echo -e "\e[31m当前发行版（${distro_name} ${distro_version}）暂不支持。\e[0m"
        exit 1
    fi
    
    # 本脚本仅支持 Ubuntu 22 及以上
    if [ "$(uname)" == "Linux" ]; then
        version_info=$(lsb_release -rs | cut -d '.' -f 1)
        # 检查是否为 Ubuntu 且版本低于 22
        if [ "$(lsb_release -is)" == "Ubuntu" ] && [ "$version_info" -lt 22 ]; then
            echo "本脚本仅支持 Ubuntu 22 及以上版本"
            exit
        fi
    fi
}
checkOS

# TODO: 这些命令在 hiddify-panel/install.sh 中已声明，这里是否还需要？
#localectl set-locale LANG=C.UTF-8 >/dev/null 2>&1
#su hiddify-panel -c update-locale LANG=C.UTF-8 >/dev/null 2>&1

export DEBIAN_FRONTEND=noninteractive
export USE_VENV=true

echo "即将开始下载所需文件 :)"
GITHUB_REPOSITORY=hiddify-config
GITHUB_USER=hiddify
GITHUB_BRANCH_OR_TAG=main

# if [ ! -d "/opt/$GITHUB_REPOSITORY" ];then
apt-get update
#apt upgrade -y
#apt -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade

apt-get install -y curl unzip
mkdir -p /opt/$GITHUB_REPOSITORY
cd /opt/$GITHUB_REPOSITORY
# 仅用于 v8 历史迁移：需要远古官方 hiddify-config v10.5.73 包才能迁移 v8 数据库。
# 这不是升级路径 —— 绝不要用它来更新。
curl -L -s -o $GITHUB_REPOSITORY.zip https://github.com/hiddify/$GITHUB_REPOSITORY/releases/download/v10.5.73/$GITHUB_REPOSITORY.zip
unzip -o $GITHUB_REPOSITORY.zip > /dev/null
rm "$GITHUB_REPOSITORY.zip"
rm -f data/services/xray/json/*.json
rm -f data/services/hiddify-core/json/*.json
source /opt/hiddify-manager/scripts/common/utils.sh
install_python
install_pypi_package pip==24.0
pip install -U hiddifypanel==8.8.99
bash scripts/install.sh --no-gui
# exit 0
# fi

hiddify_bashrc_install_menu
if [ "$CREATE_EASYSETUP_LINK" == "true" ];then
    cd /opt/$GITHUB_REPOSITORY/services/panel
    hiddify-panel-cli set-setting --key create_easysetup_link --val True
fi

hiddify-panel-cli set-setting --key auto_update --val False

read -p "按任意键进入菜单" -n 1 key
cd /opt/$GITHUB_REPOSITORY
hiddify
