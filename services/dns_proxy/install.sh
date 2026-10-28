source /opt/hiddify-manager/scripts/common/utils.sh
source /opt/hiddify-manager/scripts/common/package_manager.sh

BASE="$(cd "$(dirname "$0")" && pwd)"

# 创建 DNS 代理专用系统用户，并加入公共用户组（已存在时忽略）。
useradd --system --no-create-home dns_proxy 2>/dev/null || true
usermod -aG hiddify-common dns_proxy 2>/dev/null || true

# dnstm 路由二进制（dns_proxy 各协议共用）
# 二进制丢失时强制重新下载：packages.db 在 data/ 下，比 services/ 存活更久。
force=""
[[ -x ./dnstm ]] || force=force
if download_package dnstm dnstm "" $force; then
    chmod +x dnstm
    set_installed_version dnstm
elif [[ ! -x ./dnstm ]]; then
    echo "警告：dnstm 二进制未安装" >&2
fi

# 各协议安装脚本会下载到自己的目录，run-instance.sh 也从自身目录查找文件。
for proto in dnstt slipstream masterdns; do
    (cd "$BASE/$proto" && bash install.sh)
done

# 生成目录软链；协议/实例目录由面板导出配置时创建（dns_proxy_dump）。
mkdir -p "$HIDDIFY_GENERATED"
ln -sfn "$HIDDIFY_GENERATED/dns_proxy" "$BASE/generated"

# 安装 systemd 模板单元与路由服务
ln -sfn "$BASE/dnstt/hiddify-dnstt@.service" /etc/systemd/system/hiddify-dnstt@.service
ln -sfn "$BASE/slipstream/hiddify-slipstream@.service" /etc/systemd/system/hiddify-slipstream@.service
ln -sfn "$BASE/masterdns/hiddify-masterdns@.service" /etc/systemd/system/hiddify-masterdns@.service
ln -sfn "$BASE/hiddify-dnstm-router.service" /etc/systemd/system/hiddify-dnstm-router.service
systemctl daemon-reload
