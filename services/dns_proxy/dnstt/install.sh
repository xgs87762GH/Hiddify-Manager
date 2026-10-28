source /opt/hiddify-manager/scripts/common/utils.sh
source /opt/hiddify-manager/scripts/common/package_manager.sh

# VayDNS 服务端 —— 用于自定义代理协议 "dnstt"
# https://github.com/net2share/vaydns
# packages.db（data/）在 release 升级后依然保留，而 services/ 会被覆盖：
# 二进制丢失时必须强制下载，否则 download_package 会误报"已下载"。
force=""
[[ -x ./vaydns-server ]] || force=force
if download_package vaydns vaydns-server "" $force; then
    chmod +x vaydns-server
    set_installed_version vaydns
elif [[ ! -x ./vaydns-server ]]; then
    echo "警告：vaydns-server 二进制未安装" >&2
fi
