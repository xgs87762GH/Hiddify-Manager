#!/bin/bash
# 仅安装 Clash Meta（Mihomo）客户端二进制，不注册 systemd 服务。
# 供面板的配置测试功能直接运行 Clash YAML 订阅。
source /opt/hiddify-manager/scripts/common/utils.sh
source /opt/hiddify-manager/scripts/common/package_manager.sh

version="" # 需要固定版本时在这里填写，留空则使用最新版本

download_package clash mihomo.gz "$version" "" mihomo
# 返回 0 表示本次执行了下载，或者二进制本身缺失，都需要重新解压安装。
if [ "$?" == "0" ] || ! is_installed ./mihomo; then
    gunzip -f mihomo.gz || exit 1
    chown root:root mihomo || exit 2
    chmod +x mihomo || exit 3
    ln -sf /opt/hiddify-manager/services/clash/mihomo /usr/bin/mihomo || exit 4
    set_installed_version clash $version
fi
