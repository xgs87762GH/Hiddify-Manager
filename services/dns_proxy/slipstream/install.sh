source /opt/hiddify-manager/scripts/common/utils.sh
source /opt/hiddify-manager/scripts/common/package_manager.sh

# https://github.com/EndPositive/slipstream
# 该包在 packages.lock 中固定版本后即可下载；暂无记录时降级处理，不中断安装。
force=""
[[ -x ./slipstream-server ]] || force=force
if download_package slipstream slipstream-server "" $force; then
    chmod +x slipstream-server
    set_installed_version slipstream
elif [[ ! -x ./slipstream-server ]]; then
    echo "警告：slipstream-server 二进制未安装（请在 packages.lock 中添加 slipstream）" >&2
fi
chown dns_proxy:dns_proxy slipstream-server 2>/dev/null || true
