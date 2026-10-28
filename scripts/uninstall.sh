#!/bin/bash
# 没有这段保护时，cd 失败会让后面的清理删除调用方当前目录。
cd /opt/hiddify-manager || { echo "无法进入 /opt/hiddify-manager" >&2; exit 1; }
source /opt/hiddify-manager/scripts/common/utils.sh
function main(){
    # 停用并禁用所有单元（含模板实例与 WireGuard），确保重启后不会再被拉起
    for s in netdata hiddify-nginx $(hiddify_service_units); do
        systemctl kill "$s" 2>/dev/null
        systemctl disable "$s" 2>/dev/null
    done
    rm -rf /etc/cron.d/hiddify*
    rm -f /usr/bin/hiddify /etc/bash_completion.d/hiddify /etc/profile.d/hiddify.sh
    service cron reload
    if     [[ "$1" == "purge" ]];then
        # 一律使用绝对路径：销毁性删除不能依赖当前目录。
        rm -rf /opt/hiddify-manager/services/panel
        apt-get purge -y nginx gunicorn mariadb-* #python3-pip python3
        rm -rf /opt/hiddify-manager/*
        echo "已彻底卸载 Hiddify 面板"
    fi
}

mkdir -p /opt/hiddify-manager/data/log/
main $@|& tee /opt/hiddify-manager/data/log/uninstall.log
