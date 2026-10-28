source /opt/hiddify-manager/scripts/common/utils.sh
activate_python_venv
install_package wireguard libev-dev libevdev2 default-libmysqlclient-dev build-essential pkg-config ssh

# 创建面板运行用户并加入公共用户组
useradd -m hiddify-panel -s /bin/bash >/dev/null 2>&1
usermod -aG hiddify-common hiddify-panel

echo -n "" >> /opt/hiddify-manager/data/log/panel.log
chown hiddify-panel /opt/hiddify-manager/data/log/panel.log
chsh hiddify-panel -s /bin/bash

chown -R hiddify-panel:hiddify-panel /home/hiddify-panel/ >/dev/null 2>&1
localectl set-locale LANG=C.UTF-8 >/dev/null 2>&1
su hiddify-panel -c update-locale LANG=C.UTF-8 >/dev/null 2>&1
chown -R hiddify-panel:hiddify-panel . >/dev/null 2>&1
# 为 hiddify-panel 用户自动激活 Python 虚拟环境（已存在则跳过）
if ! grep -Fxq "source /opt/hiddify-manager/.venv313/bin/activate" "/home/hiddify-panel/.bashrc" && ! grep -Fxq "export PATH=/opt/hiddify-manager/.venv313/bin:\$PATH" "/home/hiddify-panel/.bashrc"; then
    echo "source /opt/hiddify-manager/.venv313/bin/activate" >> "/home/hiddify-panel/.bashrc"
    echo "export PATH=/opt/hiddify-manager/.venv313/bin:\$PATH" >> "/home/hiddify-panel/.bashrc"
fi


ln -sf $(pwd)/hiddify-panel.service /etc/systemd/system/hiddify-panel.service
systemctl enable hiddify-panel.service

# 后台任务原先由 Celery worker+beat 进程承担，现已合并进 hiddify-panel.service
# 内部的 APScheduler。升级时清理旧单元，避免两套调度同时运行（用量统计/备份重复执行）。
if [ -e /etc/systemd/system/hiddify-panel-background-tasks.service ]; then
    systemctl disable --now hiddify-panel-background-tasks.service 2>/dev/null || true
    rm -f /etc/systemd/system/hiddify-panel-background-tasks.service
fi

# 开发检出时直接从子模块源码安装面板（editable：改代码只需重启面板）
if [ -z "$HIDDIFY_PANLE_SOURCE_DIR" ] && is_dev_checkout && [ -f "$HIDDIFY_DIR/services/panel/src/pyproject.toml" ]; then
    export HIDDIFY_PANLE_SOURCE_DIR="$HIDDIFY_DIR/services/panel/src"
fi
if [ -n "$HIDDIFY_PANLE_SOURCE_DIR" ]; then
    echo "提示：正在从源码构建 hiddifypanel 包……"
    echo "提示：源码目录 $HIDDIFY_PANLE_SOURCE_DIR"
    build_panel_ui "$HIDDIFY_PANLE_SOURCE_DIR" || exit 1
    uv pip install -e "$HIDDIFY_PANLE_SOURCE_DIR"
fi

# 旧版依赖 cron 执行用量统计与自动备份，现已由面板内部调度替代。
rm -rf /etc/cron.d/{hiddify_usage_update,hiddify_auto_backup}
# echo "*/1 * * * * root $(pwd)/update_usage.sh" >/etc/cron.d/hiddify_usage_update
# echo "0 */6 * * * hiddify-panel $(pwd)/backup.sh" >/etc/cron.d/hiddify_auto_backup
service cron reload >/dev/null 2>&1


##### 下载 GeoIP 数据库

# 文件不存在或超过 1 天则更新
if [[ ! -e "GeoLite2-ASN.mmdb" || $(find "GeoLite2-ASN.mmdb" -mtime +1) ]]; then
    curl --connect-timeout 10 -sL -o GeoLite2-ASN.mmdb1 https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb && mv GeoLite2-ASN.mmdb1 GeoLite2-ASN.mmdb
fi
if [[ ! -e "GeoLite2-Country.mmdb" || $(find "GeoLite2-Country.mmdb" -mtime +1) ]]; then
    curl --connect-timeout 10 -sL -o GeoLite2-Country.mmdb1 https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-Country.mmdb && mv GeoLite2-Country.mmdb1 GeoLite2-Country.mmdb
fi

# bash download_yt.sh &
