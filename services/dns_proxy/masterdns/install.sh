source /opt/hiddify-manager/scripts/common/utils.sh
source /opt/hiddify-manager/scripts/common/package_manager.sh

# https://github.com/masterking32/MasterDnsVPN
# 该包在 packages.lock 中固定版本后即可下载；暂无记录时降级处理，不中断安装。
force=""
[[ -x ./bin/masterdnsvpn-server ]] || force=force
if download_package masterdns masterdnsvpn-server.zip "" $force; then
    install_package unzip
    mkdir -p bin
    unzip -o masterdnsvpn-server.zip -d bin
    mv -f bin/MasterDns* bin/masterdnsvpn-server
    chmod +x bin/masterdnsvpn-server
    set_installed_version masterdns
elif [[ ! -x ./bin/masterdnsvpn-server ]]; then
    echo "警告：masterdnsvpn-server 二进制未安装（请在 packages.lock 中添加 masterdnsvpn）" >&2
fi
chown dns_proxy:dns_proxy bin/masterdnsvpn-server 2>/dev/null || true
