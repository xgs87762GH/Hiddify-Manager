source /opt/hiddify-manager/scripts/common/utils.sh
ln -sf $(pwd)/hiddify-core.service /etc/systemd/system/hiddify-core.service
systemctl daemon-reload
systemctl enable hiddify-core.service
# Drop the old unit name if it is still installed
if [ -e /etc/systemd/system/hiddify-singbox.service ]; then
	systemctl disable --now hiddify-singbox.service 2>/dev/null || true
	rm -f /etc/systemd/system/hiddify-singbox.service
	systemctl daemon-reload
fi

mkdir -p /opt/hiddify-manager/data/hiddify-core
set_files_in_folder_readable_to_hiddify_common_group /opt/hiddify-manager/generated/hiddify-core.json

rm /opt/hiddify-manager/data/hiddify-core/tor/lock 2>/dev/null || true
if config_check_ok hiddify-core /opt/hiddify-manager/generated/hiddify-core.json \
	/opt/hiddify-manager/services/hiddify-core/hiddify-core check -c /opt/hiddify-manager/generated/hiddify-core.json; then
	systemctl reload hiddify-core.service
	systemctl start hiddify-core.service
fi
