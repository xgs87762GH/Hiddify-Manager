#!/bin/bash
# Without the guard a failed cd would make the purge below delete the caller's cwd.
cd /opt/hiddify-manager || { echo "cannot cd to /opt/hiddify-manager" >&2; exit 1; }
source /opt/hiddify-manager/scripts/common/utils.sh
function main(){
    # Every unit (also the template instances and WireGuard): stopped and disabled, so nothing comes back after a reboot
    for s in netdata hiddify-nginx $(hiddify_service_units); do
        systemctl kill "$s" 2>/dev/null
        systemctl disable "$s" 2>/dev/null
    done
    rm -rf /etc/cron.d/hiddify*
    rm -f /usr/bin/hiddify /etc/bash_completion.d/hiddify /etc/profile.d/hiddify.sh
    service cron reload
    if     [[ "$1" == "purge" ]];then
        # Absolute paths only: never depend on cwd for a destructive delete.
        rm -rf /opt/hiddify-manager/services/panel
        apt-get purge -y nginx gunicorn mariadb-* #python3-pip python3
        rm -rf /opt/hiddify-manager/*
        echo "We have completely removed hiddify panel"
    fi
}

mkdir -p /opt/hiddify-manager/data/log/
main $@|& tee /opt/hiddify-manager/data/log/uninstall.log
