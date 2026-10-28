#!/bin/bash
source /opt/hiddify-manager/scripts/common/utils.sh
source /opt/hiddify-manager/services/mysql/utils.sh
cd "$(dirname -- "$0")"

install_package mariadb-server

# 不要放进 $( )：它会设置 HIDDIFY_MYSQL_PASS_IS_NEW，供下面首次安装时的安全加固使用
ensure_mysql_password
MYSQL_PASS="$(get_mysql_password)"
migrate_mysql_datadir "$(current_mysql_datadir)" "$HIDDIFY_MYSQL_DATADIR"
configure_mysql_server || {
    error "配置 MariaDB 失败（详见上方输出），已在启动服务前中止。"
    exit 1
}
install_hiddify_mysql_unit
start_mysql_server

# 仅在首次生成密码时加固 root；每次都要把面板用户的密码同步到密码文件
if [ "${HIDDIFY_MYSQL_PASS_IS_NEW:-0}" = "1" ]; then
    setup_mysql_panel_user "$MYSQL_PASS"
    start_mysql_server
fi
# 安装流程随后会进入 services/panel，而面板只能用这组凭据连接数据库，
# 因此在这里就失败，而不是等到面板安装时才失败。
if ! sync_mysql_panel_user "$MYSQL_PASS"; then
    error "面板无法使用 MySQL，已中止安装，避免把面板装在一个连不上的数据库上。"
    exit 1
fi
