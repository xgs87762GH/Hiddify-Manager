source /opt/hiddify-manager/scripts/common/utils.sh

install_package shadowsocks-libev simple-obfs
# 全新目录下模板可能还没渲染，忽略不存在的通配符。
chmod 600 *.service* >/dev/null 2>&1 || true
if [ -f hiddify-ss-faketls.service ]; then
  ln -sf "$(pwd)/hiddify-ss-faketls.service" /etc/systemd/system/hiddify-ss-faketls.service
fi
# 清理旧版软件包自带的单元（可能不存在），任何情况下都不能让安装失败。
systemctl disable --now ss-faketls.service >/dev/null 2>&1 || true
rm -f ss-faketls.service ss-faketls.service.* >/dev/null 2>&1 || true
