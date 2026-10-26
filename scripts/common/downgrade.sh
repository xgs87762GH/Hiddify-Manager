cd /opt/hiddify-manager/services/panel

source /opt/hiddify-manager/scripts/common/utils.sh
activate_python_venv

hiddify-panel-cli downgrade
if [ ! -f hiddifypanel.db ] && [ -f hiddifypanel.db.old ]; then
    mv hiddifypanel.db.old hiddifypanel.db
fi
cd /opt/hiddify-manager


# The panel is reinstalled from YOUR fork (the official PyPI package has no fork versions)
install_panel_from_git "" pip || true
curl -L -s -o hiddify-manager.zip https://github.com/${HIDDIFY_MANAGER_REPO:-xgs87762GH/Hiddify-Manager}/releases/latest/download/hiddify-manager.zip
unzip -o hiddify-manager.zip
rm hiddify-manager.zip
ln -s /opt/hiddify-manager /opt/hiddify-config
bash scripts/install.sh
