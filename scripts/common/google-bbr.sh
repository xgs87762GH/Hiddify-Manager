#!/usr/bin/env bash
#
# 自动安装内核并启用 TCP BBR
#
# 系统要求：CentOS 6+、Debian 8+、Ubuntu 16+
#
# 版权所有 (C) 2016-2021 Teddysun <i@teddysun.com>
#
# 原始地址：https://teddysun.com/489.html
#

cur_dir="$(cd -P -- "$(dirname -- "$0")" && pwd -P)"

_red() {
    printf '\033[1;31;31m%b\033[0m' "$1"
}

_green() {
    printf '\033[1;31;32m%b\033[0m' "$1"
}

_yellow() {
    printf '\033[1;31;33m%b\033[0m' "$1"
}

_info() {
    _green "[信息] "
    printf -- "%s" "$1"
    printf "\n"
}

_warn() {
    _yellow "[警告] "
    printf -- "%s" "$1"
    printf "\n"
}

_error() {
    _red "[错误] "
    printf -- "%s" "$1"
    printf "\n"
    exit 1
}

_exists() {
    local cmd="$1"
    if eval type type > /dev/null 2>&1; then
        eval type "$cmd" > /dev/null 2>&1
    elif command > /dev/null 2>&1; then
        command -v "$cmd" > /dev/null 2>&1
    else
        which "$cmd" > /dev/null 2>&1
    fi
    local rt=$?
    return ${rt}
}

_os() {
    local os=""
    [ -f "/etc/debian_version" ] && source /etc/os-release && os="${ID}" && printf -- "%s" "${os}" && return
    [ -f "/etc/redhat-release" ] && os="centos" && printf -- "%s" "${os}" && return
}

_os_full() {
    [ -f /etc/redhat-release ] && awk '{print ($1,$3~/^[0-9]/?$3:$4)}' /etc/redhat-release && return
    [ -f /etc/os-release ] && awk -F'[= "]' '/PRETTY_NAME/{print $3,$4,$5}' /etc/os-release && return
    [ -f /etc/lsb-release ] && awk -F'[="]+' '/DESCRIPTION/{print $2}' /etc/lsb-release && return
}

_os_ver() {
    local main_ver="$( echo $(_os_full) | grep -oE  "[0-9.]+")"
    printf -- "%s" "${main_ver%%.*}"
}

_error_detect() {
    local cmd="$1"
    _info "${cmd}"
    eval ${cmd}
    if [ $? -ne 0 ]; then
        _error "命令 (${cmd}) 执行失败，请检查后重试。"
    fi
}

_is_digit(){
    local input=${1}
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        return 0
    else
        return 1
    fi
}

_is_64bit(){
    if [ $(getconf WORD_BIT) = '32' ] && [ $(getconf LONG_BIT) = '64' ]; then
        return 0
    else
        return 1
    fi
}

_version_ge(){
    test "$(echo "$@" | tr " " "\n" | sort -rV | head -n 1)" == "$1"
}

get_valid_valname(){
    local val=${1}
    local new_val=$(eval echo $val | sed 's/[-.]/_/g')
    echo ${new_val}
}

get_hint(){
    local val=${1}
    local new_val=$(get_valid_valname $val)
    eval echo "\$hint_${new_val}"
}

# 显示选择菜单
display_menu(){
    local soft=${1}
    local default=${2}
    eval local arr=(\${${soft}_arr[@]})
    local default_prompt
    if [[ "$default" != "" ]]; then
        if [[ "$default" == "last" ]]; then
            default=${#arr[@]}
        fi
        default_prompt="（默认 ${arr[$default-1]}）"
    fi
    local pick
    local hint
    local vname
    local prompt="请选择 ${soft} 版本 ${default_prompt}："

    while :
    do
        echo -e "\n------------ ${soft} 设置 ------------\n"
        for ((i=1;i<=${#arr[@]};i++ )); do
            vname="$(get_valid_valname ${arr[$i-1]})"
            hint="$(get_hint $vname)"
            [[ "$hint" == "" ]] && hint="${arr[$i-1]}"
            echo -e "${green}${i}${plain}) $hint"
        done
        echo
        read -p "${prompt}" pick
        if [[ "$pick" == "" && "$default" != "" ]]; then
            pick=${default}
            break
        fi

        if ! _is_digit "$pick"; then
            prompt="输入错误，请输入数字："
            continue
        fi

        if [[ "$pick" -lt 1 || "$pick" -gt ${#arr[@]} ]]; then
            prompt="输入错误，请输入 1 到 ${#arr[@]} 之间的数字："
            continue
        fi

        break
    done

    eval ${soft}=${arr[$pick-1]}
    vname="$(get_valid_valname ${arr[$pick-1]})"
    hint="$(get_hint $vname)"
    [[ "$hint" == "" ]] && hint="${arr[$pick-1]}"
    echo -e "\n你的选择：$hint\n"
}

get_latest_version() {
    latest_version=($(wget -qO- https://kernel.ubuntu.com/~kernel-ppa/mainline/ | awk -F'\"v' '/v[4-9]./{print $2}' | cut -d/ -f1 | grep -v - | sort -V))
    [ ${#latest_version[@]} -eq 0 ] && _error "获取最新内核版本失败。"
    kernel_arr=()
    for i in ${latest_version[@]}; do
        if _version_ge $i 5.15; then
            kernel_arr+=($i);
        fi
    done
    display_menu kernel last
    if _is_64bit; then
        deb_name=$(wget -qO- https://kernel.ubuntu.com/~kernel-ppa/mainline/v${kernel}/ | grep "linux-image" | grep "generic" | awk -F'\">' '/amd64.deb/{print $2}' | cut -d'<' -f1 | head -1)
        deb_kernel_url="https://kernel.ubuntu.com/~kernel-ppa/mainline/v${kernel}/${deb_name}"
        deb_kernel_name="linux-image-${kernel}-amd64.deb"
        modules_deb_name=$(wget -qO- https://kernel.ubuntu.com/~kernel-ppa/mainline/v${kernel}/ | grep "linux-modules" | grep "generic" | awk -F'\">' '/amd64.deb/{print $2}' | cut -d'<' -f1 | head -1)
        deb_kernel_modules_url="https://kernel.ubuntu.com/~kernel-ppa/mainline/v${kernel}/${modules_deb_name}"
        deb_kernel_modules_name="linux-modules-${kernel}-amd64.deb"
    else
        deb_name=$(wget -qO- https://kernel.ubuntu.com/~kernel-ppa/mainline/v${kernel}/ | grep "linux-image" | grep "generic" | awk -F'\">' '/i386.deb/{print $2}' | cut -d'<' -f1 | head -1)
        deb_kernel_url="https://kernel.ubuntu.com/~kernel-ppa/mainline/v${kernel}/${deb_name}"
        deb_kernel_name="linux-image-${kernel}-i386.deb"
        modules_deb_name=$(wget -qO- https://kernel.ubuntu.com/~kernel-ppa/mainline/v${kernel}/ | grep "linux-modules" | grep "generic" | awk -F'\">' '/i386.deb/{print $2}' | cut -d'<' -f1 | head -1)
        deb_kernel_modules_url="https://kernel.ubuntu.com/~kernel-ppa/mainline/v${kernel}/${modules_deb_name}"
        deb_kernel_modules_name="linux-modules-${kernel}-i386.deb"
    fi
    [ -z "${deb_name}" ] && _error "获取内核二进制包名失败，可能内核构建失败了，请换一个版本重试。"
}

get_char() {
    SAVEDSTTY=`stty -g`
    stty -echo
    stty cbreak
    dd if=/dev/tty bs=1 count=1 2> /dev/null
    stty -raw
    stty echo
    stty $SAVEDSTTY
}

check_bbr_status() {
    local param=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')
    if [[ x"${param}" == x"bbr" ]]; then
        return 0
    else
        return 1
    fi
}

check_kernel_version() {
    local kernel_version=$(uname -r | cut -d- -f1)
    if _version_ge ${kernel_version} 4.9; then
        return 0
    else
        return 1
    fi
}

# 检查系统版本
check_os() {
    if _exists "virt-what"; then
        virt="$(virt-what)"
    elif _exists "systemd-detect-virt"; then
        virt="$(systemd-detect-virt)"
    fi
    if [ -n "${virt}" -a "${virt}" = "lxc" ]; then
        _error "当前为 LXC 虚拟化，不支持。"
    fi
    if [ -n "${virt}" -a "${virt}" = "openvz" ] || [ -d "/proc/vz" ]; then
        _error "当前为 OpenVZ 虚拟化，不支持。"
    fi
    [ -z "$(_os)" ] && _error "不支持的操作系统"
    case "$(_os)" in
        ubuntu)
            [ -n "$(_os_ver)" -a "$(_os_ver)" -lt 16 ] && _error "不支持的操作系统，请升级到 Ubuntu 16+ 后重试。"
            ;;
        debian)
            [ -n "$(_os_ver)" -a "$(_os_ver)" -lt 8 ] &&  _error "不支持的操作系统，请升级到 Debian 8+ 后重试。"
            ;;
        centos)
            [ -n "$(_os_ver)" -a "$(_os_ver)" -lt 6 ] &&  _error "不支持的操作系统，请升级到 CentOS 6+ 后重试。"
            ;;
        *)
            _error "不支持的操作系统"
            ;;
    esac
}

sysctl_config() {
    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
}

install_kernel() {
    case "$(_os)" in
        centos)
            if [ -n "$(_os_ver)" ]; then
                if ! _exists "perl"; then
                    _error_detect "yum install -y perl"
                fi
                if [ "$(_os_ver)" -eq 6 ]; then
                    _error_detect "rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org"
                    rpm_kernel_url="https://dl.lamp.sh/files/"
                    if _is_64bit; then
                        rpm_kernel_name="kernel-ml-4.18.20-1.el6.elrepo.x86_64.rpm"
                        rpm_kernel_devel_name="kernel-ml-devel-4.18.20-1.el6.elrepo.x86_64.rpm"
                    else
                        rpm_kernel_name="kernel-ml-4.18.20-1.el6.elrepo.i686.rpm"
                        rpm_kernel_devel_name="kernel-ml-devel-4.18.20-1.el6.elrepo.i686.rpm"
                    fi
                    _error_detect "wget -c -t3 -T60 -O ${rpm_kernel_name} ${rpm_kernel_url}${rpm_kernel_name}"
                    _error_detect "wget -c -t3 -T60 -O ${rpm_kernel_devel_name} ${rpm_kernel_url}${rpm_kernel_devel_name}"
                    [ -s "${rpm_kernel_name}" ] && _error_detect "rpm -ivh ${rpm_kernel_name}" || _error "下载 ${rpm_kernel_name} 失败，请检查。"
                    [ -s "${rpm_kernel_devel_name}" ] && _error_detect "rpm -ivh ${rpm_kernel_devel_name}" || _error "下载 ${rpm_kernel_devel_name} 失败，请检查。"
                    rm -f ${rpm_kernel_name} ${rpm_kernel_devel_name}
                    [ ! -f "/boot/grub/grub.conf" ] && _error "找不到 /boot/grub/grub.conf，请检查。"
                    sed -i 's/^default=.*/default=0/g' /boot/grub/grub.conf
                elif [ "$(_os_ver)" -eq 7 ]; then
                    rpm_kernel_url="https://dl.lamp.sh/kernel/el7/"
                    if _is_64bit; then
                        rpm_kernel_name="kernel-ml-5.15.60-1.el7.x86_64.rpm"
                        rpm_kernel_devel_name="kernel-ml-devel-5.15.60-1.el7.x86_64.rpm"
                    else
                        _error "不支持的架构，请更换为 64 位架构。"
                    fi
                    _error_detect "wget -c -t3 -T60 -O ${rpm_kernel_name} ${rpm_kernel_url}${rpm_kernel_name}"
                    _error_detect "wget -c -t3 -T60 -O ${rpm_kernel_devel_name} ${rpm_kernel_url}${rpm_kernel_devel_name}"
                    [ -s "${rpm_kernel_name}" ] && _error_detect "rpm -ivh ${rpm_kernel_name}" || _error "下载 ${rpm_kernel_name} 失败，请检查。"
                    [ -s "${rpm_kernel_devel_name}" ] && _error_detect "rpm -ivh ${rpm_kernel_devel_name}" || _error "下载 ${rpm_kernel_devel_name} 失败，请检查。"
                    rm -f ${rpm_kernel_name} ${rpm_kernel_devel_name}
                    /usr/sbin/grub2-set-default 0
                fi
            fi
            ;;
        ubuntu|debian)
            _info "正在获取最新内核版本……"
            get_latest_version
            if [ -n "${modules_deb_name}" ]; then
                _error_detect "wget -c -t3 -T60 -O ${deb_kernel_modules_name} ${deb_kernel_modules_url}"
            fi
            _error_detect "wget -c -t3 -T60 -O ${deb_kernel_name} ${deb_kernel_url}"
            _error_detect "dpkg -i ${deb_kernel_modules_name} ${deb_kernel_name}"
            rm -f ${deb_kernel_modules_name} ${deb_kernel_name}
            _error_detect "/usr/sbin/update-grub"
            ;;
        *)
            ;; # 什么都不做
    esac
}

reboot_os() {
    echo
    _info "系统需要重启。"
    read -p "是否立即重启系统？[y/n]" is_reboot
    if [[ ${is_reboot} == "y" || ${is_reboot} == "Y" ]]; then
        reboot
    else
        _info "已取消重启……"
        exit 0
    fi
}

install_bbr() {
    if check_bbr_status; then
        echo
        _info "TCP BBR 已启用，无需操作……"
        exit 0
    fi
    if check_kernel_version; then
        echo
        _info "内核版本高于 4.9，直接设置 TCP BBR……"
        sysctl_config
        _info "TCP BBR 设置完成……"
        exit 0
    fi
    check_os
    install_kernel
    sysctl_config
    reboot_os
}

[[ $EUID -ne 0 ]] && _error "本脚本必须以 root 身份运行"
opsy=$( _os_full )
arch=$( uname -m )
lbit=$( getconf LONG_BIT )
kern=$( uname -r )

# clear
echo "---------- 系统信息 ----------"
echo " 系统    : $opsy"
echo " 架构    : $arch ($lbit 位)"
echo " 内核    : $kern"
echo "------------------------------"
echo " 自动启用 TCP BBR 脚本"
echo
echo " 来源：https://teddysun.com/489.html"
echo "------------------------------"
echo
echo "正在安装 Google BBR TCP 拥塞控制算法"

install_bbr 2>&1 | tee ${cur_dir}/install_bbr.log
