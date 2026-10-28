# bash download_wgcf.sh
source /opt/hiddify-manager/scripts/common/utils.sh
source /opt/hiddify-manager/services/warp/wireguard/utils.sh
source /opt/hiddify-manager/scripts/common/package_manager.sh
ensure_warp_data_links wireguard "$(pwd)"
install_package wireguard-tools resolvconf
download_package wgcf wgcf
# 返回 0 表示本次执行了下载，或二进制本身不可执行，都需要重新授权。
if [ "$?" == "0"  ] || [ ! -x ./wgcf ]; then
    chmod +x wgcf || exit 1
    set_installed_version wgcf
fi
