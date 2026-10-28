cd /opt/hiddify-manager/services/panel

source /opt/hiddify-manager/scripts/common/utils.sh
activate_python_venv

# 回滚面板数据库到上一个版本
hiddify-panel-cli downgrade
if [ ! -f hiddifypanel.db ] && [ -f hiddifypanel.db.old ]; then
    mv hiddifypanel.db.old hiddifypanel.db
fi
cd /opt/hiddify-manager


# 面板要从你自己的 fork 重新安装（官方 PyPI 包不含 fork 版本）
install_panel_from_git "" pip || true
curl -L -s -o hiddify-manager.zip https://github.com/${HIDDIFY_MANAGER_REPO:-xgs87762GH/Hiddify-Manager}/releases/latest/download/hiddify-manager.zip
unzip -o hiddify-manager.zip
rm hiddify-manager.zip
ln -s /opt/hiddify-manager /opt/hiddify-config
bash scripts/install.sh
